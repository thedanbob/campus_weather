#!/usr/bin/env python
# Usage: env TOKEN=<token> ./weather.py <url>

import json, os, re, struct, sys # stdlib
from datetime import datetime # stdlib
import requests, serial

def crc16_ccitt(data, init_crc=0):
    msb = init_crc >> 8
    lsb = init_crc & 255
    for b in data:
        x = b ^ msb
        x ^= (x >> 4)
        msb = (lsb ^ (x >> 3) ^ (x << 4)) & 255
        lsb = (x ^ (x << 5)) & 255
    return (msb << 8) + lsb

FORECASTS = {
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

port = serial.Serial(port="/dev/ttyUSB0", baudrate=19200, timeout=1.2)

for _ in range(3):
    port.write(b'\n')
    if port.read(2) == b'\n\r':
        break
else:
  print('Station not ready')
  port.close()
  sys.exit(1)

port.write(b'LOOP 1\n')
packet = port.read(100)
port.close()

if len(packet) < 100:
    print('Received incomplete data')
    sys.exit(1)

data = re.fullmatch(b'\x06(LOO.+\n\r.{2})', packet, flags=re.DOTALL)
if data == None or crc16_ccitt(data[1]) != 0:
    print('Received malformed packet')
    sys.exit(1)

# Extract bytes 8-9, 13-14, 15, 17-18, 34, 90 (little-endian)
pressure, temperature, wind_speed, wind_bearing, humidity, icon = struct.unpack('<7xH3xHBxH15xB55xB9x', data[1])

if pressure == 0: pressure = None
if temperature == 32767: temperature = None
if wind_speed == 255: wind_speed = None
if wind_bearing == 0: wind_bearing = None
if wind_bearing == 360: wind_bearing = 0 # 0 = no data, 360 = 0°
if humidity == 255: humidity = None

requests.post(
    sys.argv[1],
    headers={
        'Authorization': 'Bearer {}'.format(os.environ['TOKEN']),
        'Content-Type': 'application/json'
    },
    data=json.dumps({
        'state': FORECASTS[icon],
        'attributes': {
            'friendly_name': 'Campus Weather',
            'pressure': pressure / 1000,
            'temperature': temperature / 10,
            'wind_speed': wind_speed,
            'wind_bearing': wind_bearing,
            'humidity': humidity,
            'last_update': datetime.now().astimezone().isoformat(),
        }
    })
)
