#!/usr/bin/env elixir
# Usage: env TOKEN=<token> ./weather.exs <url>

Mix.install([
  :circuits_uart,
  :jason,
  :tz,
  :httpoison
])

defmodule Weather do
  import Bitwise

  def crc16_ccitt(data, init_crc \\ 0) do
    crc16_ccitt(data, init_crc >>> 8, init_crc &&& 255)
  end

  def crc16_ccitt(<<head::8, tail::bitstring>>, msb, lsb) do
    x = bxor(head, msb)
    x = bxor(x, x >>> 4)
    msb = bxor(lsb, bxor(x >>> 3, x <<< 4)) &&& 255
    lsb = bxor(x, x <<< 5) &&& 255
    crc16_ccitt(tail, msb, lsb)
  end

  def crc16_ccitt(<<>>, msb, lsb) do
    (msb <<< 8) + lsb
  end

  def is_ready?(pid), do: is_ready?(pid, "", 0)
  def is_ready?(_pid, "\n\r", count) when count < 3, do: true
  def is_ready?(_pid, _data, 3), do: false
  def is_ready?(pid, data, count) do
    if data == "", do: Circuits.UART.write(pid, "\n")

    case Circuits.UART.read(pid, 1200) do
      {:ok, <<>>} -> is_ready?(pid, "", count + 1)
      {:ok, res} -> is_ready?(pid, data <> res, count)
      _ -> false
    end
  end

  def read_packet(pid), do: read_packet(pid, "")
  def read_packet(_pid, data) when byte_size(data) >= 100, do: data
  def read_packet(pid, data) when byte_size(data) < 100 do
    case Circuits.UART.read(pid, 1200) do
      {:ok, res} when byte_size(res) > 0 -> read_packet(pid, data <> res)
      _ -> data
    end
  end
end

forecasts = %{
  8 => "sunny",
  6 => "partlycloudy",
  2 => "cloudy",
  3 => "rainy",
  18 => "snowy",
  19 => "snowy-rainy",
  7 => "rainy",
  22 => "snowy",
  23 => "snowy-rainy",
}

{:ok, pid} = Circuits.UART.start_link
Circuits.UART.open(pid, "/dev/ttyUSB0", speed: 19200, active: false)

unless Weather.is_ready?(pid) do
  IO.puts("Station not ready")
  Circuits.UART.close(pid)
  exit(:not_ready)
end

Circuits.UART.write(pid, "LOOP 1\n")
packet = Weather.read_packet(pid)
Circuits.UART.close(pid)
Circuits.UART.stop(pid)

unless byte_size(packet) == 100 do
  IO.puts("Received incorrect sized packet")
  exit(:bad_packet)
end

data = Regex.run(~r/\A\x06(LOO.+\n\r.{2})\z/s, packet, capture: :all_but_first)

if is_nil(data) || data |> List.first |> Weather.crc16_ccitt != 0 do
  IO.puts("Received malformed packet")
  exit(:bad_packet)
end

# Extract bytes 8-9, 13-14, 15, 34, 90 (little-endian)
<<_::7*8, pressure::little-2*8, _::3*8, temperature::little-2*8, wind_speed::8, _::18*8, humidity::8, _::55*8, icon::8, _::bitstring>> = data |> List.first

{:ok, date} = DateTime.now("America/Chicago", Tz.TimeZoneDatabase)
body = Jason.encode!(%{
  "state" => forecasts[icon],
  "attributes" => %{
    "friendly_name" => "Campus Weather",
    "pressure" => pressure / 1000,
    "temperature" => temperature / 10,
    "wind_speed" => wind_speed,
    "humidity" => humidity,
    "last_update" => DateTime.to_iso8601(date),
  }
})

HTTPoison.start
HTTPoison.post(
  System.argv() |> List.first,
  body,
  [
    "Authorization": "Bearer #{System.get_env("TOKEN")}",
    "Content-Type": "application/json"
  ]
)

exit(:normal)
