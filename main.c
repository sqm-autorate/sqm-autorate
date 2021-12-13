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

typedef struct {
    uint8_t type;
    uint8_t code;
    uint16_t checksum;
    uint16_t identifier;
    uint16_t sequence;
    uint32_t originalTime;
    uint32_t receiveTime;
    uint32_t transmitTime;
} icmpTs;

typedef struct {
    int sock_fd;
    struct sockaddr_in* reflectors;
    int reflectorsLength;
} thread_data;

unsigned long get_time_since_midnight_ms()
{
    struct timespec time;
    clock_gettime(CLOCK_REALTIME, &time);
    return (time.tv_sec % 86400 * 1000) + (time.tv_nsec / 1000000);
}

unsigned short calculateChecksum(void *b, int len)
{
    unsigned short *buf = b;
    unsigned int sum=0;
    unsigned short result;
  
    for ( sum = 0; len > 1; len -= 2 )
        sum += *buf++;
    if ( len == 1 )
        sum += *(unsigned char*)buf;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    result = ~sum;
    return result;
}

int sendTimestampRequest(int sock_fd, struct sockaddr_in * reflector)
{
    struct icmp icmpHdr;
    
    memset(&icmpHdr, 0, sizeof(icmpHdr));

    icmpHdr.icmp_type = ICMP_TIMESTAMP;
    icmpHdr.icmp_code = 0;
    icmpHdr.icmp_cksum = 0;
    icmpHdr.icmp_id = htons(0xFEED);
    icmpHdr.icmp_seq = 0;
    icmpHdr.icmp_otime = htonl(get_time_since_midnight_ms());
    icmpHdr.icmp_rtime = 0;
    icmpHdr.icmp_ttime = 0;

    icmpHdr.icmp_cksum = calculateChecksum(&icmpHdr, sizeof(icmpHdr));

    int t;

    if ((t = sendto(sock_fd, &icmpHdr, sizeof(icmpHdr), 0, (const struct sockaddr*) reflector, sizeof(*reflector))) == -1)
    {
        printf("something wrong: %d\n", t);
        return 1;
    }

    return 0;
}

void * receiver_loop(void * data)
{
    thread_data * threadData = (thread_data *) data;
    int sock_fd = threadData->sock_fd;

    while (1)
    {
        char buff[1024];
        int recv = recvfrom((int)sock_fd, buff, sizeof(buff), 0, NULL, NULL);
        //printf("%d\n", recv);
    }
}

void * sender_loop(void * data)
{
    thread_data * threadData = (thread_data *) data;
    int sock_fd = threadData->sock_fd;
    struct sockaddr_in * reflectors = threadData->reflectors;
    struct timespec wait_time;

    wait_time.tv_sec = 1;
    wait_time.tv_nsec = 0;

    while (1)
    {
        for (int i = 0; i < threadData->reflectorsLength; i++)
        {
            char str[INET_ADDRSTRLEN];

            inet_ntop(AF_INET, &(reflectors[i].sin_addr), str, INET_ADDRSTRLEN);
            sendTimestampRequest(sock_fd, &reflectors[i]);
        }

        nanosleep(&wait_time, NULL);
    }
}

static const char * const ips[] = {"9.9.9.9", "9.9.9.10"};

int main()
{
    int ipsLen = sizeof(ips) / sizeof(ips[0]);
    struct sockaddr_in * reflectors = malloc(sizeof(struct sockaddr_in) * ipsLen);

    for (int i = 0; i < ipsLen; i++)
    {
        inet_pton(AF_INET, ips[i], &reflectors[i].sin_addr);
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

    if ((sock_fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)) == -1) {
        printf("no socket for you\n");
        return 1;
    }

    thread_data data;
    data.sock_fd = sock_fd;
    data.reflectors = reflectors;
    data.reflectorsLength = ipsLen;

    int t;
    if ((t = pthread_create(&receiver_thread, NULL, receiver_loop, (void *) &data)) != 0)
    {
        printf("failed to create receiver thread: %d\n", t);
    }

    if ((t = pthread_create(&sender_thread, NULL, sender_loop, (void *) &data)) != 0)
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
    setsockopt(sock_fd, SOL_SOCKET, SO_RCVTIMEO, &read_timeout, sizeof read_timeout);*/



    return 0;
}