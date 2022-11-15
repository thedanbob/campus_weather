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

# Extract bytes 8-9, 13-14, 15, 34, 90 (little-endian)
decoded = struct.unpack('<7xH3xHB18xB55xB9x', data[1])

requests.post(
    sys.argv[0],
    headers={
        'Authorization': 'Bearer {}'.format(os.environ['TOKEN']),
        'Content-Type': 'application/json'
    },
    data=json.dumps({
        'state': FORECASTS[decoded[4]],
        'attributes': {
            'friendly_name': 'Campus Weather',
            'pressure': decoded[0] / 1000,
            'temperature': decoded[1] / 10,
            'wind_speed': decoded[2],
            'humidity': decoded[3],
            'last_update': datetime.now().astimezone().isoformat(),
        }
    })
)
