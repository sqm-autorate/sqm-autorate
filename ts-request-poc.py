import socket
from datetime import datetime
from math import floor
from os import getpid
from struct import pack, unpack
from sys import exit
from threading import Thread
from time import sleep

target_ip = "9.9.9.9"
packet_id = getpid() & 0xFFFF

sock = None


def get_time_since_midnight_ms():
    now = datetime.now()
    ms_as_int = (
        floor(
            (
                now - now.replace(hour=0, minute=0, second=0, microsecond=0)
            ).total_seconds()
        )
        * 1000
    )  # 1s = 1000ms
    return ms_as_int


def carry_around_add(a, b):
    c = a + b
    return (c & 0xFFFF) + (c >> 16)


def checksum(msg):
    s = 0
    for i in range(0, len(msg), 2):
        w = msg[i] + (msg[i + 1] << 8)
        s = carry_around_add(s, w)
    return ~s & 0xFFFF


def send_ts_ping():
    print(packet_id)
    print(sock)

    while True:
        # ICMP timestamp header
        # Type - 1 byte
        # Code - 1 byte:
        # Checksum - 2 bytes
        # Identifier - 2 bytes
        # Sequence number - 2 bytes
        # Original timestamp - 4 bytes
        # Received timestamp - 4 bytes
        # Transmit timestamp - 4 bytes
        ip_type = 13
        ip_code = 0
        ip_csum = 0
        ip_id = packet_id
        ip_seq = 0
        ip_orig_ts = get_time_since_midnight_ms()
        ip_rx_ts = 0
        ip_tx_ts = 0

        # Initial pack before checksum
        ip_header = pack(
            "!BBHHHLLL",
            ip_type,
            ip_code,
            ip_csum,
            ip_id,
            ip_seq,
            ip_orig_ts,
            ip_rx_ts,
            ip_tx_ts,
        )

        # Re-pack with calculated checksum
        ip_csum = checksum(ip_header)
        ip_header = pack(
            "!BBHHHLLL",
            ip_type,
            ip_code,
            ip_csum,
            ip_id,
            ip_seq,
            ip_orig_ts,
            ip_rx_ts,
            ip_tx_ts,
        )

        sock.sendto(ip_header, (target_ip, 0))
        print("SENT")
        sleep(1)


def receive_ts_ping():
    while True:
        print("CHECKING")
        data, addr = sock.recvfrom(1024)
        reply_header = data[20:28]
        type, code, csum, pkt_id, sequence = unpack("!BBHHH", reply_header)
        print(pkt_id)
        if pkt_id == packet_id:
            print("GOT ONE!!!!")
            print(addr)
        sleep(0.01)


if __name__ == "__main__":
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        # sock.setblocking(False)
        sock.settimeout(0.00005)  # 50usec

        recv_thread = Thread(target=receive_ts_ping)
        send_thread = Thread(target=send_ts_ping)

        recv_thread.daemon = True
        send_thread.daemon = True

        recv_thread.start()
        send_thread.start()

        recv_thread.join()
        send_thread.join()
    except socket.error as msg:
        print("Socket could not be created")
        print(f"Error was: {msg}")
        exit()
