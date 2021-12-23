#include <arpa/inet.h>
#include <assert.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>

struct icmp_timestamp_hdr
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
	int sock_fd;
	struct sockaddr_in *reflectors;
	int reflectorsLength;
} thread_data;

struct timespec get_time()
{
	struct timespec time;
	clock_gettime(CLOCK_REALTIME, &time);
	return time;
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

int sendICMPTimestampRequest(int sock_fd, struct sockaddr_in *reflector)
{
	struct icmp_timestamp_hdr hdr;

	memset(&hdr, 0, sizeof(hdr));

	struct timespec now = get_time();

	hdr.type = ICMP_TIMESTAMP;
	hdr.identifier = htons(0xFEED);
	hdr.originateTime = htonl(now.tv_sec);
	hdr.originateTimeNs = htonl(now.tv_nsec);

	hdr.checksum = calculateChecksum(&hdr, sizeof(hdr));

	int t;

	if ((t = sendto(sock_fd, &hdr, sizeof(hdr), 0, (const struct sockaddr *)reflector, sizeof(*reflector))) == -1)
	{
		printf("something wrong: %d\n", t);
		return 1;
	}

	return 0;
}

void *receiver_loop(void *data)
{
	thread_data *threadData = (thread_data *)data;
	int sock_fd = threadData->sock_fd;

	while (1)
	{
		struct icmp_timestamp_hdr hdr;
		struct sockaddr_in remote_addr;
		socklen_t addr_len = sizeof(remote_addr);
		int recv = recvfrom((int)sock_fd, &hdr, sizeof(hdr), 0, (struct sockaddr *)&remote_addr, &addr_len);

		struct timespec now = get_time();

		if (recv != 32)
		{
			printf("wrong: %d\n", recv);
			continue;
		}

		if (hdr.type != ICMP_TIMESTAMPREPLY)
		{
			printf("get outta here: %d\n", hdr.type);
			continue;
		}

		char ip[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &(remote_addr.sin_addr), ip, INET_ADDRSTRLEN);

		unsigned long originate_ts = (ntohl(hdr.originateTime) % 86400 * 1000) + (ntohl(hdr.originateTimeNs) / 1000000);
		unsigned long received_ts = (ntohl(hdr.receiveTime) % 86400 * 1000) + (ntohl(hdr.receiveTimeNs) / 1000000);
		unsigned long transmit_ts = (ntohl(hdr.transmitTime) % 86400 * 1000) + (ntohl(hdr.transmitTimeNs) / 1000000);
		unsigned long now_ts = (now.tv_sec % 86400 * 1000) + (now.tv_nsec / 1000000);
		unsigned long rtt = now_ts - originate_ts;
		unsigned long uplink_time = received_ts - originate_ts;
		unsigned long downlink_time = now_ts - transmit_ts;

		printf("Reflector IP: %s  |  Current time: %ld  |  Originate: %ld  |  Received time: %ld  |  Transmit time: %ld  |  RTT: %ld  |  UL time: %ld  |  DL time: %ld\n", ip, now_ts, originate_ts, received_ts, transmit_ts, rtt, uplink_time, downlink_time);
	}
}

void *sender_loop(void *data)
{
	thread_data *threadData = (thread_data *)data;
	int sock_fd = threadData->sock_fd;
	struct sockaddr_in *reflectors = threadData->reflectors;
	struct timespec wait_time;

	wait_time.tv_sec = 1;
	wait_time.tv_nsec = 0;

	while (1)
	{
		for (int i = 0; i < threadData->reflectorsLength; i++)
		{
			char str[INET_ADDRSTRLEN];

			inet_ntop(AF_INET, &(reflectors[i].sin_addr), str, INET_ADDRSTRLEN);
			sendICMPTimestampRequest(sock_fd, &reflectors[i]);
		}

		nanosleep(&wait_time, NULL);
	}
}

static const char *const ips[] = {"65.21.108.153", "5.161.66.148", "216.128.149.82", "108.61.220.16", "185.243.217.26", "185.175.56.188", "176.126.70.119"};

int main()
{
	int ipsLen = sizeof(ips) / sizeof(ips[0]);
	struct sockaddr_in *reflectors = malloc(sizeof(struct sockaddr_in) * ipsLen);

	for (int i = 0; i < ipsLen; i++)
	{
		inet_pton(AF_INET, ips[i], &reflectors[i].sin_addr);
		reflectors[i].sin_port = htons(62222);
	}

	for (int i = 0; i < ipsLen; i++)
	{
		char str[INET_ADDRSTRLEN];

		inet_ntop(AF_INET, &(reflectors[i].sin_addr), str, INET_ADDRSTRLEN);
		printf("%s\n", str);
	}

	pthread_t receiver_thread;
	pthread_t sender_thread;

	int sock_fd;

	// if ((sock_fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)) == -1) {
	if ((sock_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)) == -1)
	{
		printf("no socket for you\n");
		return 1;
	}

	thread_data data;
	data.sock_fd = sock_fd;
	data.reflectors = reflectors;
	data.reflectorsLength = ipsLen;

	int t;
	if ((t = pthread_create(&receiver_thread, NULL, receiver_loop, (void *)&data)) != 0)
	{
		printf("failed to create receiver thread: %d\n", t);
	}

	if ((t = pthread_create(&sender_thread, NULL, sender_loop, (void *)&data)) != 0)
	{
		printf("failed to create sender thread: %d\n", t);
	}

	void *receiver_status;
	void *sender_status;

	if ((t = pthread_join(receiver_thread, &receiver_status)) != 0)
	{
		printf("Error in receiver thread join: %d\n", t);
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
