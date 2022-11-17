#!/usr/bin/env node
// Usage: env TOKEN=<token> ./weather.js <url>

const https = require('node:https') // stdlib
const { SerialPort } = require('serialport')
const { ByteLengthParser } = require('@serialport/parser-byte-length')

const crc16_ccitt = function(data, init_crc=0) {
  let msb = init_crc >> 8
  let lsb = init_crc & 255

  data.forEach(function(b) {
    x = b ^ msb
    x ^= (x >> 4)
    msb = (lsb ^ (x >> 3) ^ (x << 4)) & 255
    lsb = (x ^ (x << 5)) & 255
  })

  return (msb << 8) + lsb
}

const FORECASTS = {
  8: 'sunny',
  6: 'partlycloudy',
  2: 'cloudy',
  3: 'rainy',
  18: 'snowy',
  19: 'snowy-rainy',
  7: 'rainy',
  22: 'snowy',
  23: 'snowy-rainy',
}

const port = new SerialPort({ path: '/dev/ttyUSB0', baudRate: 19200 })
const readyParser = new ByteLengthParser({ length: 2 })
const packetParser = new ByteLengthParser({ length: 100 })

// Set timer for two more wakeup attempts after initial (bottom of file)
let count = 0
let readyTimer = setInterval(function() {
  if (++count == 3) {
    console.log('Station not ready')
    port.close()
    process.exit(1)
  }

  port.write('\n')
}, 1200)

// Once console wakes, replace parser, request packet, and setup packet timeout
let packetTimer
const readyCallback = function(data) {
  if (data != '\n\r') return

  clearInterval(readyTimer)

  port.unpipe(readyParser)
  port.pipe(packetParser)
  packetParser.once('data', packetCallback)

  port.write('LOOP 1\n')

  packetTimer = setTimeout(function() {
    console.log('Timed out before receiving packet')
    process.exit(1)
  }, 1200)
}

// Process and send the received packet
const packetCallback = function(packet) {
  clearTimeout(packetTimer)
  port.close()

  if (!new String(packet).match(/^\x06LOO.+\n\r.{2}$/s) || crc16_ccitt(packet.slice(1)) != 0) {
    console.log('Received malformed packet')
    process.exit(1)
  }

  // Extract bytes 8-9, 13-14, 15, 34, 90 (little-endian)
  // Packet has extra byte \x06 at the beginning
  let pressure = packet.readUInt16LE(8),
      temperature = packet.readUInt16LE(13),
      wind_speed = packet.readUInt8(15),
      humidity = packet.readUInt8(34),
      icon = packet.readUInt8(90)

  if (pressure == 0) pressure = null
  if (temperature == 32767) temperature = null
  if (wind_speed == 255) wind_speed = null
  if (humidity == 255) humidity = null

  let req = https.request(process.argv[2], {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env['TOKEN']}`,
      'Content-Type': 'application/json'
    }
  })

  req.write(JSON.stringify({
    'state': FORECASTS[icon],
    'attributes': {
      'friendly_name': 'Campus Weather',
      'pressure': pressure / 1000,
      'temperature': temperature / 10,
      'wind_speed': wind_speed,
      'humidity': humidity,
      'last_update': new Date(),
    }
  }))

  req.end()
}

// Attempt to wake console
port.pipe(readyParser).on('data', readyCallback)
port.write('\n')
