#include <arpa/inet.h>
#include <assert.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <asm/socket.h>
#include <sys/time.h>
#include <time.h>
#include <linux/net_tstamp.h>

unsigned long sentICMP = 0;
unsigned long sentUDP = 0;
unsigned long receivedICMP = 0;
unsigned long receivedUDP = 0;

struct icmp_timestamp_hdr
{
	uint8_t type;
	uint8_t code;
	uint16_t checksum;
	uint16_t identifier;
	uint16_t sequence;
	uint32_t originateTime;
	uint32_t receiveTime;
	uint32_t transmitTime;
};

struct udp_timestamp_hdr
{
	uint8_t type;
	uint8_t code;
	uint16_t checksum;
	uint16_t identifier;
	uint16_t sequence;
	uint32_t originateTime;
	uint32_t originateTimeNs;
	uint32_t receiveTime;
	uint32_t receiveTimeNs;
	uint32_t transmitTime;
	uint32_t transmitTimeNs;
};

typedef struct
{
	int icmp_sock_fd;
	int udp_sock_fd;
	struct sockaddr_in *reflectors;
	int reflectorsLength;
} thread_data;

void hexDump (
    const char * desc,
    const void * addr,
    const int len,
    int perLine
) {
    // Silently ignore silly per-line values.

    if (perLine < 4 || perLine > 64) perLine = 16;

    int i;
    unsigned char buff[perLine+1];
    const unsigned char * pc = (const unsigned char *)addr;

    // Output description if given.

    if (desc != NULL) printf ("%s:\n", desc);

    // Length checks.

    if (len == 0) {
        printf("  ZERO LENGTH\n");
        return;
    }
    if (len < 0) {
        printf("  NEGATIVE LENGTH: %d\n", len);
        return;
    }

    // Process every byte in the data.

    for (i = 0; i < len; i++) {
        // Multiple of perLine means new or first line (with line offset).

        if ((i % perLine) == 0) {
            // Only print previous-line ASCII buffer for lines beyond first.

            if (i != 0) printf ("  %s\n", buff);

            // Output the offset of current line.

            printf ("  %04x ", i);
        }

        // Now the hex code for the specific character.

        printf (" %02x", pc[i]);

        // And buffer a printable ASCII character for later.

        if ((pc[i] < 0x20) || (pc[i] > 0x7e)) // isprint() may be better.
            buff[i % perLine] = '.';
        else
            buff[i % perLine] = pc[i];
        buff[(i % perLine) + 1] = '\0';
    }

    // Pad out last line if not exactly perLine characters.

    while ((i % perLine) != 0) {
        printf ("   ");
        i++;
    }

    // And print the final ASCII buffer.

    printf ("  %s\n", buff);
}

struct timespec get_time()
{
	struct timespec time;
	clock_gettime(CLOCK_REALTIME, &time);
	return time;
}

unsigned long get_time_since_midnight_ms()
{
    struct timespec time;
    clock_gettime(CLOCK_REALTIME, &time);

    return (time.tv_sec % 86400 * 1000) + (time.tv_nsec / 1000000);
}

unsigned short calculateChecksum(void *b, int len)
{
	unsigned short *buf = b;
	unsigned int sum = 0;
	unsigned short result;

	for (sum = 0; len > 1; len -= 2)
		sum += *buf++;
	if (len == 1)
		sum += *(unsigned char *)buf;
	sum = (sum >> 16) + (sum & 0xFFFF);
	sum += (sum >> 16);
	result = ~sum;
	return result;
}

int sendICMPTimestampRequest(int sock_fd, struct sockaddr_in *reflector, int seq)
{
	struct icmp_timestamp_hdr hdr;

	memset(&hdr, 0, sizeof(hdr));

	hdr.type = ICMP_TIMESTAMP;
	hdr.identifier = htons(0xFEED);
	hdr.sequence = seq;
	hdr.originateTime = htonl(get_time_since_midnight_ms());

	hdr.checksum = calculateChecksum(&hdr, sizeof(hdr));

	int t;

	if ((t = sendto(sock_fd, &hdr, sizeof(hdr), 0, (const struct sockaddr *)reflector, sizeof(*reflector))) == -1)
	{
		printf("something wrong: %d\n", t);
		return 1;
	}

	sentICMP++;

	return 0;
}

int sendUDPTimestampRequest(int sock_fd, struct sockaddr_in *reflector, int seq)
{
	struct udp_timestamp_hdr hdr;

	memset(&hdr, 0, sizeof(hdr));

	struct timespec now = get_time();

	hdr.type = ICMP_TIMESTAMP;
	hdr.identifier = htons(0xFEED);
	hdr.sequence = seq;
	hdr.originateTime = htonl(now.tv_sec);
	hdr.originateTimeNs = htonl(now.tv_nsec);

	hdr.checksum = calculateChecksum(&hdr, sizeof(hdr));

	int t;

	if ((t = sendto(sock_fd, &hdr, sizeof(hdr), 0, (const struct sockaddr *)reflector, sizeof(*reflector))) == -1)
	{
		printf("something wrong: %d\n", t);
		return 1;
	}

	sentUDP++;

	return 0;
}

int get_rx_timestamp(int sock_fd, struct timespec * rx_timestamp)
{
	struct msghdr msg;
	struct iovec iov;
	char buffer[2048];
	char control[1024];

	iov.iov_base = buffer;
	iov.iov_len = 2048;

	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	msg.msg_control = control;
	msg.msg_controllen = 1024;

	int got = recvmsg(sock_fd, &msg, 0);

	if (!got)
		return -1;

	for (struct cmsghdr * cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL; cmsg = CMSG_NXTHDR(&msg, cmsg))
	{
		if (cmsg->cmsg_level != SOL_SOCKET)
			continue;

		switch (cmsg->cmsg_type)
		{
			case SO_TIMESTAMPNS_OLD:
				memcpy(rx_timestamp, CMSG_DATA(cmsg), sizeof(struct timespec));
				return 0;
		}
	}

	return -1;
}

void *icmp_receiver_loop(void *data)
{
	thread_data *threadData = (thread_data *)data;
	int sock_fd = threadData->icmp_sock_fd;

	while (1)
	{
		char * buff = malloc(100);
		struct icmp_timestamp_hdr * hdr;
		struct sockaddr_in remote_addr;
		socklen_t addr_len = sizeof(remote_addr);
		struct timespec rxTimestamp;
		int recv = recvfrom((int)sock_fd, buff, 100, 0, (struct sockaddr *)&remote_addr, &addr_len);

		if (recv < 0)
			continue;

		int len = (*buff & 0x0F) * 4;

		if (len + sizeof(struct icmp_timestamp_hdr) > recv)
		{
			printf("Not enough data, skipping\n");
			continue;
		}

		hdr = (struct icmp_timestamp_hdr *) (buff + len);

		if (hdr->type != ICMP_TIMESTAMPREPLY)
		{
			printf("icmp: get outta here: %d\n", hdr->type);
			continue;
		}

		if (get_rx_timestamp(sock_fd, &rxTimestamp) == -1)
		{
			printf("couldn't get rx ts, fallback to current time\n");
			rxTimestamp = get_time();
		}

		char ip[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &(remote_addr.sin_addr), ip, INET_ADDRSTRLEN);

		unsigned long now_ts = (rxTimestamp.tv_sec % 86400 * 1000) + (rxTimestamp.tv_nsec / 1000000);
		unsigned long rtt = now_ts - ntohl(hdr->originateTime);
		unsigned long uplink_time = ntohl(hdr->receiveTime) - ntohl(hdr->originateTime);
		unsigned long downlink_time = now_ts - ntohl(hdr->transmitTime);

		printf("Type: %4s  |  Reflector IP: %15s  |  Seq: %5d  |  Current time: %8ld  |  Originate: %8ld  |  Received time: %8ld  |  Transmit time: %8ld  |  RTT: %5ld  |  UL time: %5ld  |  DL time: %5ld\n", 
		"ICMP", ip, ntohs(hdr->sequence), now_ts, (unsigned long) ntohl(hdr->originateTime), (unsigned long) ntohl(hdr->receiveTime), (unsigned long) ntohl(hdr->transmitTime), rtt, uplink_time, downlink_time);
		free(buff);

		receivedICMP++;
	}
}

void *udp_receiver_loop(void *data)
{
	thread_data *threadData = (thread_data *)data;
	int sock_fd = threadData->udp_sock_fd;

	while (1)
	{
		struct udp_timestamp_hdr hdr;
		struct sockaddr_in remote_addr;
		socklen_t addr_len = sizeof(remote_addr);
		struct timespec rxTimestamp;
		int recv = recvfrom((int)sock_fd, &hdr, sizeof(hdr), 0, (struct sockaddr *)&remote_addr, &addr_len);

		if (recv == -1)
			continue;

		if (recv != 32)
		{
			printf("udp: wrong: %d\n", recv);
			continue;
		}

		if (hdr.type != ICMP_TIMESTAMPREPLY)
		{
			printf("udp: get outta here: %d\n", hdr.type);
			continue;
		}

		if (get_rx_timestamp(sock_fd, &rxTimestamp) == -1)
		{
			printf("couldn't get rx ts, fallback to current time\n");
			rxTimestamp = get_time();
		}

		char ip[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &(remote_addr.sin_addr), ip, INET_ADDRSTRLEN);

		unsigned long originate_ts = (ntohl(hdr.originateTime) % 86400 * 1000) + (ntohl(hdr.originateTimeNs) / 1000000);
		unsigned long received_ts = (ntohl(hdr.receiveTime) % 86400 * 1000) + (ntohl(hdr.receiveTimeNs) / 1000000);
		unsigned long transmit_ts = (ntohl(hdr.transmitTime) % 86400 * 1000) + (ntohl(hdr.transmitTimeNs) / 1000000);
		unsigned long now_ts = (rxTimestamp.tv_sec % 86400 * 1000) + (rxTimestamp.tv_nsec / 1000000);
		unsigned long rtt = now_ts - originate_ts;
		unsigned long uplink_time = received_ts - originate_ts;
		unsigned long downlink_time = now_ts - transmit_ts;

		printf("Type: %4s  |  Reflector IP: %15s  |  Seq: %5d  |  Current time: %8ld  |  Originate: %8ld  |  Received time: %8ld  |  Transmit time: %8ld  |  RTT: %5ld  |  UL time: %5ld  |  DL time: %5ld\n", 
		"UDP", ip, ntohs(hdr.sequence), now_ts, originate_ts, received_ts, transmit_ts, rtt, uplink_time, downlink_time);

		receivedUDP++;
	}
}

void *sender_loop(void *data)
{
	thread_data *threadData = (thread_data *)data;
	int icmp_sock_fd = threadData->icmp_sock_fd;
	int udp_sock_fd = threadData->udp_sock_fd;
	struct sockaddr_in *reflectors = threadData->reflectors;
	struct timespec wait_time;

	wait_time.tv_sec = 1;
	wait_time.tv_nsec = 0;

	int seq = 0;

	while (1)
	{
		for (int i = 0; i < threadData->reflectorsLength; i++)
		{
			char str[INET_ADDRSTRLEN];

			inet_ntop(AF_INET, &(reflectors[i].sin_addr), str, INET_ADDRSTRLEN);
			sendICMPTimestampRequest(icmp_sock_fd, &reflectors[i], htons(seq));
			sendUDPTimestampRequest(udp_sock_fd, &reflectors[i], htons(seq));
		}

		seq++;
		nanosleep(&wait_time, NULL);
	}

	printf("ICMP sent: %5ld  |  ICMP received: %5ld\n", sentICMP, receivedICMP);
	printf("UDP sent: %5ld   |  UDP received: %5ld\n", sentUDP, receivedUDP);

	exit(0);
}

// Fail_Safes reflectors "216.128.149.82", "108.61.220.16", (doesn't respond to ICMP TS atm)
static const char *const ips[] = {"65.21.108.153", "5.161.66.148", "185.243.217.26", "185.175.56.188", "176.126.70.119"};

int main()
{
	int ipsLen = sizeof(ips) / sizeof(ips[0]);
	struct sockaddr_in *reflectors = malloc(sizeof(struct sockaddr_in) * ipsLen);

	for (int i = 0; i < ipsLen; i++)
	{
		inet_pton(AF_INET, ips[i], &reflectors[i].sin_addr);
		reflectors[i].sin_port = htons(62222);
	}

	pthread_t icmp_receiver_thread;
	pthread_t udp_receiver_thread;
	pthread_t sender_thread;

	int icmp_sock_fd;
	int udp_sock_fd;

	if ((icmp_sock_fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)) == -1)
	{
		printf("no icmp socket for you\n");
		return 1;
	}

	if ((udp_sock_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)) == -1)
	{
		printf("no udp socket for you\n");
		return 1;
	}

	int ts_enable = 1;

	if (setsockopt(icmp_sock_fd, SOL_SOCKET, SO_TIMESTAMPNS_OLD, &ts_enable, sizeof(ts_enable)) == -1)
	{
		printf("couldn't set ts option on icmp socket\n");
		return 1;
	}

	if (setsockopt(udp_sock_fd, SOL_SOCKET, SO_TIMESTAMPNS_OLD, &ts_enable, sizeof(ts_enable)) == -1)
	{
		printf("couldn't set ts option on udp socket\n");
		return 1;
	}

	thread_data data;
	data.icmp_sock_fd = icmp_sock_fd;
	data.udp_sock_fd = udp_sock_fd;
	data.reflectors = reflectors;
	data.reflectorsLength = ipsLen;

	int t;
	if ((t = pthread_create(&icmp_receiver_thread, NULL, icmp_receiver_loop, (void *)&data)) != 0)
	{
		printf("failed to create icmp receiver thread: %d\n", t);
	}

	if ((t = pthread_create(&udp_receiver_thread, NULL, udp_receiver_loop, (void *)&data)) != 0)
	{
		printf("failed to create udp receiver thread: %d\n", t);
	}

	if ((t = pthread_create(&sender_thread, NULL, sender_loop, (void *)&data)) != 0)
	{
		printf("failed to create sender thread: %d\n", t);
	}

	void *icmp_receiver_status;
	void *udp_receiver_status;
	void *sender_status;

	if ((t = pthread_join(icmp_receiver_thread, &icmp_receiver_status)) != 0)
	{
		printf("Error in icmp receiver thread join: %d\n", t);
	}

	if ((t = pthread_join(udp_receiver_thread, &udp_receiver_status)) != 0)
	{
		printf("Error in udp receiver thread join: %d\n", t);
	}

	if ((t = pthread_join(sender_thread, &sender_status)) != 0)
	{
		printf("Error in sender thread join: %d\n", t);
	}

	/*struct timeval read_timeout;
	read_timeout.tv_sec = 0;
	read_timeout.tv_usec = 100000;
	//setsockopt(sock_fd, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof read_timeout);*/

	return 0;
}
