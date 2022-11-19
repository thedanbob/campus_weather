#!/usr/bin/env ruby
# Usage: env TOKEN=<token> ./weather.rb <url>

require 'json' # stdlib
require 'net/http' #stdlib
require 'serialport'

def crc16_ccitt(data, init_crc=0)
  msb = init_crc >> 8
  lsb = init_crc & 255

  data.each_byte do |b|
    x = b ^ msb
    x ^= (x >> 4)
    msb = (lsb ^ (x >> 3) ^ (x << 4)) & 255
    lsb = (x ^ (x << 5)) & 255
  end

  (msb << 8) + lsb
end

Forecasts = {
  8 => 'sunny',
  6 => 'partlycloudy',
  2 => 'cloudy',
  3 => 'rainy',
  18 => 'snowy',
  19 => 'snowy-rainy',
  7 => 'rainy',
  22 => 'snowy',
  23 => 'snowy-rainy'
}

socket = SerialPort.new('/dev/ttyUSB0', 19200)
socket.read_timeout = 1200

3.times do |i|
  socket.write("\n")
  break if socket.read(2) == "\n\r"

  if i == 2
    puts 'Station not ready'
    socket.close
    exit 1
  end
end

socket.write("LOOP 1\n")
packet = socket.read(100)
socket.close

if packet.nil? || packet.size < 100
  puts 'Received incomplete data'
  exit 1
end

data = packet.match(/\A\x06(LOO.+\n\r.{2})\z/m)
if data.nil? || crc16_ccitt(data[1]) != 0
  puts 'Received malformed packet'
  exit 1
end

# Extract bytes 8-9, 13-14, 15, 17-18, 34, 90 (little-endian)
pressure, temperature, wind_speed, wind_bearing, humidity, icon = data[1].unpack('@7v@12vCxv@33C@89C')

pressure = nil if pressure == 0
temperature = nil if temperature == 32767
wind_speed = nil if if wind_speed == 255
wind_bearing = nil if wind_bearing == 0
wind_bearing = 0 if wind_bearing == 360 # 0 = no data, 360 = 0°
humidity = nil if humidity == 255

Net::HTTP.post(
  URI(ARGV[0]),
  JSON.dump(
    state: Forecasts[decoded[4]],
    attributes: {
      friendly_name: 'Campus Weather',
      pressure: pressure / 1000.0,
      temperature: temperature / 10.0,
      wind_speed: wind_speed,
      wind_bearing: wind_bearing,
      humidity: humidity,
      last_update: Time.now.strftime('%FT%T%z'),
    }
  ),
  'Authorization' => "Bearer #{ENV['TOKEN']}",
  'Content-Type' => 'application/json',
)
