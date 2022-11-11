#!/usr/bin/env node
// Usage: env TOKEN=<token> ./weather.js <url></url>

const https = require('node:https') // stdlib
const { SerialPort } = require('serialport')
const { ByteLengthParser } = require('@serialport/parser-byte-length')

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

const port = new SerialPort({ path: '/dev/ttyUSB0', baudRate: 19200 })
const readyParser = new ByteLengthParser({ length: 2 })
const packetParser = new ByteLengthParser({ length: 100 })

let count = 0
let readyTimer = setInterval(function() {
  if (++count == 3) {
    console.log('Station not ready')
    port.close()
    process.exit(1)
  }

  port.write('\n')
}, 1200)

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

const packetCallback = function(packet) {
  clearTimeout(packetTimer)
  port.close()

  if (!new String(packet).match(/^\x06LOO.+\n\r.{2}$/s) || crc16_ccitt(packet.slice(1)) != 0) {
    console.log('Received malformed packet')
    process.exit(1)
  }

  // Extract bytes 8-9, 13-14, 15, 34, 90 (little-endian)
  // Packet has extra byte \x06 at the beginning
  decoded = [packet.readUInt16LE(8), packet.readUInt16LE(13), packet.readUInt8(15), packet.readUInt8(34), packet.readUInt8(90)]

  let req = https.request(process.argv[2], {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env['TOKEN']}`,
      'Content-Type': 'application/json'
    }
  })

  req.write(JSON.stringify({
    'state': FORECASTS[decoded[4]],
    'attributes': {
      'friendly_name': 'Campus Weather',
      'pressure': decoded[0] / 1000,
      'temperature': decoded[1] / 10,
      'wind_speed': decoded[2],
      'humidity': decoded[3],
      'last_update': new Date(),
    }
  }))

  req.end()
}

port.pipe(readyParser).on('data', readyCallback)
port.write('\n')
