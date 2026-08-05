#!/usr/bin/env python3
"""Pruebas directas de los protocolos de estado de Minecraft Java y Bedrock."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time


RAKNET_MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")


def parse_endpoint(value: str, default_port: int) -> tuple[str, int]:
    value = value.strip()
    if not value:
        raise ValueError("la direccion esta vacia")

    if value.startswith("["):
        closing = value.find("]")
        if closing == -1:
            raise ValueError("direccion IPv6 entre corchetes invalida")
        host = value[1:closing]
        remainder = value[closing + 1 :]
        port = int(remainder[1:]) if remainder.startswith(":") else default_port
        return host, port

    if value.count(":") == 1:
        host, raw_port = value.rsplit(":", 1)
        return host, int(raw_port)

    # Una IPv6 sin corchetes usa el puerto predeterminado.
    return value, default_port


def encode_varint(value: int) -> bytes:
    value &= 0xFFFFFFFF
    encoded = bytearray()
    while True:
        current = value & 0x7F
        value >>= 7
        if value:
            current |= 0x80
        encoded.append(current)
        if not value:
            return bytes(encoded)


def read_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("el destino cerro la conexion")
        data.extend(chunk)
    return bytes(data)


def read_varint(sock: socket.socket) -> int:
    value = 0
    for index in range(5):
        current = read_exact(sock, 1)[0]
        value |= (current & 0x7F) << (7 * index)
        if not current & 0x80:
            return value
    raise ValueError("VarInt demasiado largo")


def probe_java(host: str, port: int, timeout: float) -> str:
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        encoded_host = host.encode("utf-8")
        handshake = (
            encode_varint(0)
            + encode_varint(-1)
            + encode_varint(len(encoded_host))
            + encoded_host
            + struct.pack(">H", port)
            + encode_varint(1)
        )
        connection.sendall(encode_varint(len(handshake)) + handshake)
        connection.sendall(b"\x01\x00")

        packet_length = read_varint(connection)
        packet_id = read_varint(connection)
        if packet_id != 0:
            raise ValueError(f"respuesta Java inesperada: packet_id={packet_id}")
        json_length = read_varint(connection)
        if json_length > packet_length or json_length > 1_000_000:
            raise ValueError(f"longitud de estado Java invalida: {json_length}")
        status = json.loads(read_exact(connection, json_length).decode("utf-8"))

    version = status.get("version", {}).get("name", "desconocida")
    players = status.get("players", {})
    return f"version={version}, jugadores={players.get('online', '?')}/{players.get('max', '?')}"


def probe_bedrock(host: str, port: int, timeout: float) -> str:
    timestamp = int(time.time() * 1000)
    ping = b"\x01" + struct.pack(">q", timestamp) + RAKNET_MAGIC + struct.pack(">q", 0)
    errors: list[str] = []

    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
    for family, socktype, protocol, _, address in addresses:
        try:
            with socket.socket(family, socktype, protocol) as connection:
                connection.settimeout(timeout)
                connection.sendto(ping, address)
                response, _ = connection.recvfrom(65_535)
            if len(response) < 35 or response[0] != 0x1C:
                raise ValueError("respuesta RakNet invalida")
            if response[17:33] != RAKNET_MAGIC:
                raise ValueError("magic RakNet invalido")
            text_length = struct.unpack(">H", response[33:35])[0]
            status_text = response[35 : 35 + text_length].decode("utf-8", "replace")
            fields = status_text.split(";")
            version = fields[3] if len(fields) > 3 else "desconocida"
            online = fields[4] if len(fields) > 4 else "?"
            maximum = fields[5] if len(fields) > 5 else "?"
            return f"version={version}, jugadores={online}/{maximum}"
        except (OSError, ValueError) as error:
            errors.append(f"{address}: {error}")

    raise ConnectionError("; ".join(errors) if errors else "no se resolvio ninguna direccion UDP")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("edition", choices=("java", "bedrock"))
    parser.add_argument("endpoint")
    parser.add_argument("--label", default="Minecraft")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    default_port = 25565 if args.edition == "java" else 19132
    try:
        host, port = parse_endpoint(args.endpoint, default_port)
        if not 1 <= port <= 65535:
            raise ValueError("puerto fuera de rango")
        if args.edition == "java":
            details = probe_java(host, port, args.timeout)
        else:
            details = probe_bedrock(host, port, args.timeout)
    except (OSError, ValueError, EOFError, json.JSONDecodeError) as error:
        print(f"[FALLO] {args.label}: {args.endpoint} - {type(error).__name__}: {error}")
        return 1

    print(f"[OK] {args.label}: {args.endpoint} - {details}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
