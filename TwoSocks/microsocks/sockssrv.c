/*
   MicroSocks - multithreaded, small, efficient SOCKS5 server.

   Copyright (C) 2017 rofl0r.

   This is the successor of "rocksocks5", and it was written with
   different goals in mind:

   - prefer usage of standard libc functions over homegrown ones
   - no artificial limits
   - do not aim for minimal binary size, but for minimal source code size,
     and maximal readability, reusability, and extensibility.

   as a result of that, ipv4, dns, and ipv6 is supported out of the box
   and can use the same code, while rocksocks5 has several compile time
   defines to bring down the size of the resulting binary to extreme values
   like 10 KB static linked when only ipv4 support is enabled.

   still, if optimized for size, *this* program when static linked against musl
   libc is not even 50 KB. that's easily usable even on the cheapest routers.

*/

#define _GNU_SOURCE
#include <unistd.h>
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <signal.h>
#include <poll.h>
#include <arpa/inet.h>
#include <sys/time.h>
#include <errno.h>
#include <limits.h>

#include "sblist.h"
#include "server.h"
#include "sockssrv.h"

/* timeout in microseconds on resource exhaustion to prevent excessive
   cpu usage. */
#ifndef FAILURE_TIMEOUT
#define FAILURE_TIMEOUT 64
#endif

#ifndef MAX
#define MAX(x, y) ((x) > (y) ? (x) : (y))
#endif

#ifdef PTHREAD_STACK_MIN
#define THREAD_STACK_SIZE MAX(8*1024, PTHREAD_STACK_MIN)
#else
#define THREAD_STACK_SIZE 64*1024
#endif

#if defined(__APPLE__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 64*1024
#elif defined(__GLIBC__) || defined(__FreeBSD__) || defined(__sun__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 32*1024
#endif

#define TCP_COPY_BUFFER_SIZE (32 * 1024)
#define TCP_COPY_ACCOUNTING_FLUSH_BYTES (64 * 1024)

static int quiet;
static const char* auth_user;
static const char* auth_pass;
static sblist* auth_ips;
static pthread_rwlock_t auth_ips_lock = PTHREAD_RWLOCK_INITIALIZER;
static const struct server* server;
static pthread_mutex_t connection_event_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t transfer_totals_lock = PTHREAD_MUTEX_INITIALIZER;
static twosocks_connection_event_handler connection_event_handler;
static int64_t next_connection_identifier_value = 1;
static uint64_t total_downloaded_bytes = 0;
static uint64_t total_uploaded_bytes = 0;

struct thread {
    pthread_t pt;
    struct client client;
    enum socksstate state;
    volatile int  done;
};

struct service_addr {
    enum socks5_addr_type type;
    char* host;
    unsigned short port;
};

#ifndef CONFIG_LOG
#define CONFIG_LOG 1
#endif
#if CONFIG_LOG
/* we log to stderr because it's not using line buffering, i.e. malloc which would need
   locking when called from different threads. for the same reason we use dprintf,
   which writes directly to an fd. */
#define dolog(...) do { if(!quiet) dprintf(2, __VA_ARGS__); } while(0)
#else
static void dolog(const char* fmt, ...) { }
#endif

struct socks5_addrport {
    enum socks5_addr_type type;
    char addr[MAX_DNS_LEN + 1];
    unsigned short port;
};

void twosocks_set_connection_event_handler(twosocks_connection_event_handler handler) {
    pthread_mutex_lock(&connection_event_lock);
    connection_event_handler = handler;
    pthread_mutex_unlock(&connection_event_lock);
}

static void record_downloaded_bytes(size_t count) {
    pthread_mutex_lock(&transfer_totals_lock);
    total_downloaded_bytes += (uint64_t)count;
    pthread_mutex_unlock(&transfer_totals_lock);
}

static void record_uploaded_bytes(size_t count) {
    pthread_mutex_lock(&transfer_totals_lock);
    total_uploaded_bytes += (uint64_t)count;
    pthread_mutex_unlock(&transfer_totals_lock);
}

uint64_t twosocks_total_downloaded_bytes(void) {
    uint64_t count;
    pthread_mutex_lock(&transfer_totals_lock);
    count = total_downloaded_bytes;
    pthread_mutex_unlock(&transfer_totals_lock);
    return count;
}

uint64_t twosocks_total_uploaded_bytes(void) {
    uint64_t count;
    pthread_mutex_lock(&transfer_totals_lock);
    count = total_uploaded_bytes;
    pthread_mutex_unlock(&transfer_totals_lock);
    return count;
}

static int64_t next_connection_identifier(void) {
    int64_t identifier;
    pthread_mutex_lock(&connection_event_lock);
    identifier = next_connection_identifier_value++;
    pthread_mutex_unlock(&connection_event_lock);
    return identifier;
}

static twosocks_connection_event_handler current_connection_event_handler(void) {
    twosocks_connection_event_handler handler;
    pthread_mutex_lock(&connection_event_lock);
    handler = connection_event_handler;
    pthread_mutex_unlock(&connection_event_lock);
    return handler;
}

static void emit_connection_event(
    int64_t identifier,
    enum twosocks_connection_protocol protocol,
    enum twosocks_connection_state state,
    const char* host,
    unsigned short port,
    enum errorcode error_code
) {
    twosocks_connection_event_handler handler = current_connection_event_handler();
    if(handler) {
        handler(identifier, protocol, state, host, port, error_code);
    }
}

static void emit_addrport_connection_event(
    int64_t identifier,
    enum twosocks_connection_protocol protocol,
    enum twosocks_connection_state state,
    const struct socks5_addrport* addrport,
    enum errorcode error_code
) {
    if(addrport) {
        emit_connection_event(identifier, protocol, state, addrport->addr, addrport->port, error_code);
    }
}


int compareSocks5Addrport(const struct socks5_addrport* addrport1, const struct socks5_addrport* addrport2) {
    if (addrport1->type == addrport2->type && 
        strcmp(addrport1->addr, addrport2->addr) == 0 && 
        addrport1->port == addrport2->port) {
        return 0;
    }
    return -1;
}

int resolveSocks5Addrport(struct socks5_addrport* addrport, enum socks5_socket_type  stype, union sockaddr_union* addr) {
     struct addrinfo* ai;
     if (stype == TCP_SOCKET) {
        /* there's no suitable errorcode in rfc1928 for dns lookup failure */
        if(resolve_tcp(addrport->addr, addrport->port, &ai)) return -EC_GENERAL_FAILURE;
    } else if (stype == UDP_SOCKET) {
        if(resolve_udp(addrport->addr, addrport->port, &ai)) return -EC_GENERAL_FAILURE;
    } else {
        abort();
    }

    memcpy(addr, ai->ai_addr, ai->ai_addrlen);
    freeaddrinfo(ai);
    return 0;
}

static int parse_addrport(unsigned char *buf, size_t n, struct socks5_addrport* addrport) {
    assert(addrport != NULL);
    if (n < 2) return -EC_GENERAL_FAILURE;
    int af = AF_INET;
    int minlen = 1 + 4 + 2, l;
    char namebuf[MAX_DNS_LEN + 1];

    enum socks5_addr_type type = buf[0];
    switch(type) {
        case SOCKS5_IPV6: /* ipv6 */
            af = AF_INET6;
            minlen = 1 + 16 + 2;
            /* fall through */
        case SOCKS5_IPV4: /* ipv4 */
            if(n < minlen) return -EC_GENERAL_FAILURE;
            if(namebuf != inet_ntop(af, buf+1, namebuf, sizeof namebuf))
                return -EC_GENERAL_FAILURE; /* malformed or too long addr */
            break;
        case SOCKS5_DNS: /* dns name */
            l = buf[1];
            minlen = 1 + (1 + l) + 2 ;
            if(n < minlen) return -EC_GENERAL_FAILURE;
            memcpy(namebuf, buf+2, l);
            namebuf[l] = 0;
            break;
        default:
            return -EC_ADDRESSTYPE_NOT_SUPPORTED;
    }
    
    addrport->type = type;
    addrport->addr[sizeof addrport->addr - 1] = '\0';
    strncpy(addrport->addr, namebuf, sizeof addrport->addr -1);
    addrport->port = (buf[minlen-2] << 8) | buf[minlen-1];
    return minlen;
}

static int parse_socks_request_header(
    unsigned char *buf,
    size_t n,
    int* cmd,
    union sockaddr_union* svc_addr,
    struct socks5_addrport* requested_addr
) {
    assert(svc_addr != NULL);
    if(n < 3) return -EC_GENERAL_FAILURE;
    if(buf[0] != VERSION) return -EC_GENERAL_FAILURE;
    if(buf[1] != CONNECT && buf[1] != UDP_ASSOCIATE) return -EC_COMMAND_NOT_SUPPORTED; /* we support only CONNECT and UDP ASSOCIATE method */
    *cmd = buf[1];
    if(buf[2] != RSV) return -EC_GENERAL_FAILURE; /* malformed packet */

    struct socks5_addrport addrport;
    int ret = parse_addrport(buf + 3, n - 3, &addrport);
    if (ret < 0) {
        return ret;
    }
    if(requested_addr) {
        *requested_addr = addrport;
    }
    int socktype = *cmd == CONNECT? TCP_SOCKET : UDP_SOCKET;
    ret = resolveSocks5Addrport(&addrport, socktype, svc_addr);
    if (ret < 0) return ret;
    return EC_SUCCESS;
}

static int connect_socks_target(union sockaddr_union* remote_addr, struct client *client) {
    int fd = socket(SOCKADDR_UNION_AF(remote_addr), SOCK_STREAM, 0);
    if(fd == -1) {
        eval_errno:
        if(fd != -1) close(fd);
        switch(errno) {
            case ETIMEDOUT:
                return -EC_TTL_EXPIRED;
            case EPROTOTYPE:
            case EPROTONOSUPPORT:
            case EAFNOSUPPORT:
                return -EC_ADDRESSTYPE_NOT_SUPPORTED;
            case ECONNREFUSED:
                return -EC_CONN_REFUSED;
            case ENETDOWN:
            case ENETUNREACH:
                return -EC_NET_UNREACHABLE;
            case EHOSTUNREACH:
                return -EC_HOST_UNREACHABLE;
            case EBADF:
            default:
            perror("socket/connect");
            return -EC_GENERAL_FAILURE;
        }
    }
    if(connect(fd, (struct sockaddr*)remote_addr, SOCKADDR_UNION_LENGTH(remote_addr)) == -1)
        goto eval_errno;

    if(CONFIG_LOG) {
        char clientname[256];
        int af = SOCKADDR_UNION_AF(&client->addr);
        void *ipdata = SOCKADDR_UNION_ADDRESS(&client->addr);
        inet_ntop(af, ipdata, clientname, sizeof clientname);
        char targetname[256];
        af = SOCKADDR_UNION_AF(remote_addr);
        ipdata = SOCKADDR_UNION_ADDRESS(remote_addr);
        inet_ntop(af, ipdata, targetname, sizeof targetname);
        dolog("client[%d] %s: connected to %s:%d\n", client->fd, clientname, 
            targetname, ntohs(SOCKADDR_UNION_PORT(remote_addr)));
    }
    return fd;
}

static int is_authed(union sockaddr_union *client, union sockaddr_union *authedip) {
    int af = SOCKADDR_UNION_AF(authedip);
    if(af == SOCKADDR_UNION_AF(client)) {
        size_t cmpbytes = af == AF_INET ? 4 : 16;
        void *cmp1 = SOCKADDR_UNION_ADDRESS(client);
        void *cmp2 = SOCKADDR_UNION_ADDRESS(authedip);
        if(!memcmp(cmp1, cmp2, cmpbytes)) return 1;
    }
    return 0;
}

static int is_in_authed_list(union sockaddr_union *caddr) {
    size_t i;
    for(i=0;i<sblist_getsize(auth_ips);i++)
        if(is_authed(caddr, sblist_get(auth_ips, i)))
            return 1;
    return 0;
}

static void add_auth_ip(union sockaddr_union *caddr) {
    sblist_add(auth_ips, caddr);
}

static enum authmethod check_auth_method(unsigned char *buf, size_t n, struct client*client) {
    if(buf[0] != 5) return AM_INVALID;
    size_t idx = 1;
    if(idx >= n ) return AM_INVALID;
    int n_methods = buf[idx];
    idx++;
    while(idx < n && n_methods > 0) {
        if(buf[idx] == AM_NO_AUTH) {
            if(!auth_user) return AM_NO_AUTH;
            else if(auth_ips) {
                int authed = 0;
                if(pthread_rwlock_rdlock(&auth_ips_lock) == 0) {
                    authed = is_in_authed_list(&client->addr);
                    pthread_rwlock_unlock(&auth_ips_lock);
                }
                if(authed) return AM_NO_AUTH;
            }
        } else if(buf[idx] == AM_USERNAME) {
            if(auth_user) return AM_USERNAME;
        }
        idx++;
        n_methods--;
    }
    return AM_INVALID;
}

static void send_auth_response(int fd, int version, enum authmethod meth) {
    unsigned char buf[2];
    buf[0] = version;
    buf[1] = meth;
    write(fd, buf, 2);
}

static ssize_t send_response(int fd, enum errorcode ec, union sockaddr_union* addr) {
    void* addr_ptr = SOCKADDR_UNION_ADDRESS(addr);
    assert(addr_ptr != NULL);
    unsigned short port = ntohs(SOCKADDR_UNION_PORT(addr));
    // IPv6 takes 22 bytes, which is the longest
    unsigned char buf[4 + 16 + 2] = {VERSION, ec, RSV};
    size_t len = 0;
    if (SOCKADDR_UNION_AF(addr) == AF_INET) {
        buf[3] = SOCKS5_IPV4;
        memcpy(buf+4, addr_ptr, 4);
        buf[8] = port >> 8;
        buf[9] = port & 0xFF;
        len = 10;
    } else if (SOCKADDR_UNION_AF(addr) == AF_INET6) {
        buf[3] = SOCKS5_IPV6;
        memcpy(buf+4, addr_ptr, 16);
        buf[20] = port >> 8;
        buf[21] = port & 0xFF;
        len = 22;
    } else {
        abort();
    }
    return write(fd, buf, len);
}

static int sockaddr_is_unspecified(const union sockaddr_union* addr) {
    if(SOCKADDR_UNION_AF(addr) == AF_INET) {
        return addr->v4.sin_addr.s_addr == htonl(INADDR_ANY);
    } else if(SOCKADDR_UNION_AF(addr) == AF_INET6) {
        return IN6_IS_ADDR_UNSPECIFIED(&addr->v6.sin6_addr);
    }
    return 1;
}

static int populate_udp_response_addr(int udp_fd, int tcp_fd, union sockaddr_union* response_addr) {
    socklen_t udp_len = sizeof(*response_addr);
    if(getsockname(udp_fd, (struct sockaddr*)response_addr, &udp_len)) {
        return -1;
    }
    if(!sockaddr_is_unspecified(response_addr)) {
        return 0;
    }

    union sockaddr_union tcp_local_addr;
    socklen_t tcp_len = sizeof(tcp_local_addr);
    if(getsockname(tcp_fd, (struct sockaddr*)&tcp_local_addr, &tcp_len)) {
        return -1;
    }
    if(SOCKADDR_UNION_AF(&tcp_local_addr) != SOCKADDR_UNION_AF(response_addr)) {
        return 0;
    }

    if(SOCKADDR_UNION_AF(response_addr) == AF_INET) {
        response_addr->v4.sin_addr = tcp_local_addr.v4.sin_addr;
    } else if(SOCKADDR_UNION_AF(response_addr) == AF_INET6) {
        response_addr->v6.sin6_addr = tcp_local_addr.v6.sin6_addr;
        response_addr->v6.sin6_scope_id = tcp_local_addr.v6.sin6_scope_id;
    }
    return 0;
}

static void send_error(int fd, enum errorcode ec) {
    /* position 4 contains ATYP, the address type, which is the same as used in the connect
       request. we're lazy and return always IPV4 address type in errors. */
    char buf[10] = { 5, ec, 0, 1 /*AT_IPV4*/, 0,0,0,0, 0,0 };
    write(fd, buf, 10);
}

static void flush_pending_transfer_totals(size_t *downloaded_bytes, size_t *uploaded_bytes) {
    if(*downloaded_bytes) {
        record_downloaded_bytes(*downloaded_bytes);
        *downloaded_bytes = 0;
    }
    if(*uploaded_bytes) {
        record_uploaded_bytes(*uploaded_bytes);
        *uploaded_bytes = 0;
    }
}

static enum twosocks_connection_state copyloop(int fd1, int fd2) {
    struct pollfd fds[2] = {
        [0] = {.fd = fd1, .events = POLLIN},
        [1] = {.fd = fd2, .events = POLLIN},
    };
    char buf[TCP_COPY_BUFFER_SIZE];
    size_t pending_downloaded_bytes = 0;
    size_t pending_uploaded_bytes = 0;

    while(1) {
        /* inactive connections are reaped after 15 min to free resources.
           usually programs send keep-alive packets so this should only happen
           when a connection is really unused. */
        switch(poll(fds, 2, 60*15*1000)) {
            case 0:
                flush_pending_transfer_totals(&pending_downloaded_bytes, &pending_uploaded_bytes);
                return TWOSOCKS_CONNECTION_CLOSED;
            case -1:
                if(errno == EINTR || errno == EAGAIN) continue;
                else perror("poll");
                flush_pending_transfer_totals(&pending_downloaded_bytes, &pending_uploaded_bytes);
                return TWOSOCKS_CONNECTION_ERROR;
        }
        int infd = (fds[0].revents & POLLIN) ? fd1 : fd2;
        int outfd = infd == fd2 ? fd1 : fd2;
        ssize_t sent = 0, n = read(infd, buf, sizeof buf);
        if(n == 0) {
            flush_pending_transfer_totals(&pending_downloaded_bytes, &pending_uploaded_bytes);
            return TWOSOCKS_CONNECTION_CLOSED;
        }
        if(n < 0) {
            flush_pending_transfer_totals(&pending_downloaded_bytes, &pending_uploaded_bytes);
            return TWOSOCKS_CONNECTION_ERROR;
        }
        while(sent < n) {
            ssize_t m = write(outfd, buf+sent, n-sent);
            if(m < 0) {
                flush_pending_transfer_totals(&pending_downloaded_bytes, &pending_uploaded_bytes);
                return TWOSOCKS_CONNECTION_ERROR;
            }
            sent += m;
        }
        if(infd == fd1) {
            pending_uploaded_bytes += (size_t)n;
            if(pending_uploaded_bytes >= TCP_COPY_ACCOUNTING_FLUSH_BYTES) {
                record_uploaded_bytes(pending_uploaded_bytes);
                pending_uploaded_bytes = 0;
            }
        } else {
            pending_downloaded_bytes += (size_t)n;
            if(pending_downloaded_bytes >= TCP_COPY_ACCOUNTING_FLUSH_BYTES) {
                record_downloaded_bytes(pending_downloaded_bytes);
                pending_downloaded_bytes = 0;
            }
        }
    }
}

// caller must free socks5_addr manually
static ssize_t extract_udp_data(unsigned char* buf, ssize_t n, struct socks5_addrport* addrport) {
    if (n < 3) return -EC_GENERAL_FAILURE;
    if (buf[0] != RSV || buf[1] != RSV) return -EC_GENERAL_FAILURE;
    if (buf[2] != 0) return -EC_GENERAL_FAILURE;  // framentation not supported

    ssize_t offset = 3;
    int ret = parse_addrport(buf + offset, n - offset, addrport);
    if (ret < 0) {
        return ret;
    }
    assert(ret > 0);

    offset += ret;
    return offset;
}

struct fd_socks5addr {
    int fd;
    int64_t connection_id;
    struct socks5_addrport addrport;
};

int compare_fd_socks5addr_by_fd(char* item1, char* item2) {
    struct fd_socks5addr* i1 = ( struct fd_socks5addr*)item1;
    struct fd_socks5addr* i2 = ( struct fd_socks5addr*)item2;
    if (i1->fd == i2->fd) return 0;
    return 1;
}

int compare_fd_socks5addr_by_addrport(char* item1, char* item2) {
    struct fd_socks5addr* ap1 = ( struct fd_socks5addr*)item1;
    struct fd_socks5addr* ap2 = ( struct fd_socks5addr*)item2;
    return compareSocks5Addrport(&ap1->addrport, &ap2->addrport);
}

static void copy_loop_udp(int tcp_fd, int udp_fd) {
    // add tcp_fd and udp_fd to poll    
    int poll_fds = 2;
    struct pollfd fds[1024] = {
        [0] = {.fd = tcp_fd, .events = POLLIN},
        [1] = {.fd = udp_fd, .events = POLLIN},
    };

    int udp_is_bound = 1;
    union sockaddr_union client_addr;
    socklen_t socklen = sizeof client_addr;
    if (-1 == getpeername(udp_fd, (struct sockaddr*)&client_addr, &socklen)) {
        if (errno == ENOTCONN) {
            udp_is_bound = 0;
            dprintf(1, "fd %d is not bound yet\n", udp_fd);
        } else {
            abort();
        }
    }

    ssize_t n, ret;
    struct fd_socks5addr item;
    sblist* sock_list = sblist_new(sizeof(struct fd_socks5addr), 1);
    int association_failed = 0;
    int64_t failed_connection_id = 0;
    enum errorcode failed_error_code = EC_GENERAL_FAILURE;
    while(1) {
        switch(poll(fds, poll_fds, 60*15*1000)) {
            case 0:
                goto UDP_LOOP_END;
            case -1:
                if(errno == EINTR || errno == EAGAIN) continue;
                else perror("poll");
                association_failed = 1;
                goto UDP_LOOP_END;
        }

        // support up to 1024 bytes of data
        unsigned char buf[MAX_SOCKS5_HEADER_LEN + 1024];
        // TCP socket
        if (fds[0].revents & POLLIN) {
            n = read(fds[0].fd, buf, sizeof(buf) - 1);
            if (n == 0) {
                // SOCKS5 TCP connection closed
                goto UDP_LOOP_END;
            }
            if (n == -1) {
                if(errno == EINTR || errno == EAGAIN) continue;
                else perror("read from tcp socket");
                association_failed = 1;
                goto UDP_LOOP_END;
            }
            buf[n - 1] = '\0';
            dprintf(1, "received unexpectedly from TCP socket in UDP associate: %s", buf);
            association_failed = 1;
            goto UDP_LOOP_END;
        }

        // client UDP socket
        if (fds[1].revents & POLLIN) {
            if (!udp_is_bound) {
                socklen = sizeof client_addr;
                n = recvfrom(udp_fd, buf, sizeof(buf), 0, (struct sockaddr*)&client_addr, &socklen);
            } else {
                n = recv(udp_fd, buf, sizeof(buf), 0);
            }
            if (n == -1) {
                if(errno == EINTR || errno == EAGAIN) continue;
                perror("recv from udp socket");
                association_failed = 1;
                goto UDP_LOOP_END;
            }
            if (!udp_is_bound) {
                if (connect(udp_fd, (const struct sockaddr*)&client_addr, socklen)) {
                    perror("connect");
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }
                udp_is_bound = 1;
                dprintf(1, "fd %d is bound now\n", udp_fd);
            }
        
            ssize_t offset = extract_udp_data(buf, n, &item.addrport);
            if (offset < 0) {
                dprintf(2, "failed to extract from udp packet %ld", offset);
                association_failed = 1;
                goto UDP_LOOP_END;
            }

            int send_fd = 0;
            int64_t send_connection_id = 0;
            int idx = sblist_search(sock_list, (char*)&item, compare_fd_socks5addr_by_addrport);
            if (idx != -1) {
                struct fd_socks5addr* item_found = (struct fd_socks5addr*)sblist_item_from_index(sock_list, idx);
                send_fd = item_found->fd;
                send_connection_id = item_found->connection_id;
            } else {
                union sockaddr_union target_addr;
                ret = resolveSocks5Addrport(&item.addrport, UDP_SOCKET, &target_addr);
                if (ret < 0) {
                    dprintf(2, "failed to resolve socks5 addrport, %ld", ret);
                    failed_connection_id = next_connection_identifier();
                    failed_error_code = ret * -1;
                    emit_addrport_connection_event(
                        failed_connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                        TWOSOCKS_CONNECTION_ERROR,
                        &item.addrport,
                        failed_error_code
                    );
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }

                // create a new socket
                int fd = socket(SOCKADDR_UNION_AF(&target_addr), SOCK_DGRAM, 0);
                if(fd == -1) {
                    perror("socket");
                    failed_connection_id = next_connection_identifier();
                    failed_error_code = EC_GENERAL_FAILURE;
                    emit_addrport_connection_event(
                        failed_connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                        TWOSOCKS_CONNECTION_ERROR,
                        &item.addrport,
                        failed_error_code
                    );
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }
                if (-1 == connect(fd, (const struct sockaddr*)&target_addr, ((const struct sockaddr*)&target_addr)->sa_len)) {
                    perror("connect");
                    send_error(tcp_fd, EC_GENERAL_FAILURE);
                    close(fd);
                    failed_connection_id = next_connection_identifier();
                    failed_error_code = EC_GENERAL_FAILURE;
                    emit_addrport_connection_event(
                        failed_connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                        TWOSOCKS_CONNECTION_ERROR,
                        &item.addrport,
                        failed_error_code
                    );
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }
                item.fd = fd;
                item.connection_id = next_connection_identifier();
                if(!sblist_add(sock_list, &item)) {
                    close(fd);
                    failed_connection_id = item.connection_id;
                    failed_error_code = EC_GENERAL_FAILURE;
                    emit_addrport_connection_event(
                        item.connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                        TWOSOCKS_CONNECTION_ERROR,
                        &item.addrport,
                        failed_error_code
                    );
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }

                // add to polling fds
                if(poll_fds >= 1024) {
                    close(fd);
                    sblist_delete(sock_list, sblist_getsize(sock_list) - 1);
                    failed_connection_id = item.connection_id;
                    failed_error_code = EC_GENERAL_FAILURE;
                    emit_addrport_connection_event(
                        item.connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                        TWOSOCKS_CONNECTION_ERROR,
                        &item.addrport,
                        failed_error_code
                    );
                    association_failed = 1;
                    goto UDP_LOOP_END;
                }
                fds[poll_fds].fd = fd;
                fds[poll_fds].events = POLL_IN;
                poll_fds++;
                send_fd = fd;
                send_connection_id = item.connection_id;
                emit_addrport_connection_event(
                    item.connection_id,
                    TWOSOCKS_CONNECTION_PROTOCOL_UDP,
                    TWOSOCKS_CONNECTION_OPEN,
                    &item.addrport,
                    EC_SUCCESS
                );
                if (CONFIG_LOG) {
                        char targetname[256];
                        int af = SOCKADDR_UNION_AF(&target_addr);
                        void *ipdata = SOCKADDR_UNION_ADDRESS(&target_addr);
                        unsigned short port = ntohs(SOCKADDR_UNION_PORT(&target_addr));
                        inet_ntop(af, ipdata, targetname, sizeof targetname);
                        dolog("UDP fd[%d] remote address is %s:%d\n", send_fd, targetname, port);
                    }

            }
            ssize_t ret = send(send_fd, buf + offset, n - offset, 0);
            if (ret < 0) {
                perror("send");
                association_failed = 1;
                failed_connection_id = send_connection_id;
                failed_error_code = EC_GENERAL_FAILURE;
                goto UDP_LOOP_END;
            }
            record_uploaded_bytes((size_t)ret);
        }

        // UDP sockets for target addresses
        int i;
        for (i = 2; i < poll_fds; i++) {
            if (fds[i].revents & POLLIN) {
                item.fd = fds[i].fd;
                int idx = sblist_search(sock_list, (char *)&item, compare_fd_socks5addr_by_fd);
                if (idx == -1) {
                    dprintf(2, "UDP socket not found");
                    goto UDP_LOOP_END;
                }
                struct fd_socks5addr *item = (struct fd_socks5addr*)sblist_item_from_index(sock_list, idx);
                buf[0] = RSV;
                buf[1] = RSV;
                buf[2] = 0; // FRAG
                struct socks5_addrport* addrport = &item->addrport;
                buf[3] = addrport->type;
                size_t offset = 4;
                if (addrport->type == SOCKS5_DNS) {
                    size_t len = strlen(item->addrport.addr);
                    buf[offset++] = len;
                    memcpy(buf + offset, addrport->addr, len);
                    offset += len;
                } else if (addrport->type == SOCKS5_IPV4) {
                    struct in_addr addr_in4;
                    if (1 != inet_pton(AF_INET, addrport->addr, &addr_in4)) {
                        dprintf(2, "invalid IPv4 address, %s", addrport->addr);
                        goto UDP_LOOP_END;
                    }
                    memcpy(buf + offset, &addr_in4, sizeof addr_in4);
                    offset += sizeof addr_in4;
                } else if (addrport->type == SOCKS5_IPV6) {
                    struct in6_addr addr_in6;
                    if (1 != inet_pton(AF_INET6, addrport->addr, &addr_in6)) {
                        dprintf(2, "invalid IPv6 address, %s", addrport->addr);
                        goto UDP_LOOP_END;
                    }
                    memcpy(buf + offset, &addr_in6, sizeof addr_in6);
                    offset += sizeof addr_in6;
                } else {
                    abort();
                }
                buf[offset++] = addrport->port >> 8;
                buf[offset++] = addrport->port & 0xFF;
                n = recv(fds[i].fd, buf + offset, sizeof(buf) - offset, 0);
                if(n <= 0) {
                    perror("recv from target address");
                    association_failed = 1;
                    failed_connection_id = item->connection_id;
                    failed_error_code = EC_GENERAL_FAILURE;
                    goto UDP_LOOP_END;
                }
                ret = write(udp_fd, buf, offset + n);
                if (ret < 0) {
                    perror("write to udp_fd");
                    association_failed = 1;
                    failed_connection_id = item->connection_id;
                    failed_error_code = EC_GENERAL_FAILURE;
                    goto UDP_LOOP_END;
                }
                record_downloaded_bytes((size_t)n);
            }
        }
    }
UDP_LOOP_END:
    for (size_t i = 0; i < sblist_getsize(sock_list); i++) {
        struct fd_socks5addr* tracked_item = (struct fd_socks5addr*)sblist_item_from_index(sock_list, i);
        enum twosocks_connection_state final_state = TWOSOCKS_CONNECTION_CLOSED;
        enum errorcode final_error = EC_SUCCESS;
        if(association_failed) {
            if(failed_connection_id == 0 || tracked_item->connection_id == failed_connection_id) {
                final_state = TWOSOCKS_CONNECTION_ERROR;
                final_error = failed_error_code;
            }
        }
        emit_addrport_connection_event(
            tracked_item->connection_id,
            TWOSOCKS_CONNECTION_PROTOCOL_UDP,
            final_state,
            &tracked_item->addrport,
            final_error
        );
    }
    for (int i = 2; i < poll_fds; i++)
        close(fds[i].fd);
    sblist_free(sock_list);
}

static enum errorcode check_credentials(unsigned char* buf, size_t n) {
    if(n < 5) return EC_GENERAL_FAILURE;
    if(buf[0] != 1) return EC_GENERAL_FAILURE;
    unsigned ulen, plen;
    ulen=buf[1];
    if(n < 2 + ulen + 2) return EC_GENERAL_FAILURE;
    plen=buf[2+ulen];
    if(n < 2 + ulen + 1 + plen) return EC_GENERAL_FAILURE;
    char user[256], pass[256];
    memcpy(user, buf+2, ulen);
    memcpy(pass, buf+2+ulen+1, plen);
    user[ulen] = 0;
    pass[plen] = 0;
    if(!strcmp(user, auth_user) && !strcmp(pass, auth_pass)) return EC_SUCCESS;
    return EC_NOT_ALLOWED;
}

int udp_svc_setup(union sockaddr_union* client_addr) {
    int fd = socket(SOCKADDR_UNION_AF(client_addr), SOCK_DGRAM, 0);
    if(fd == -1) {
        if(fd != -1) close(fd);
        switch(errno) {
            case ETIMEDOUT:
                return -EC_TTL_EXPIRED;
            case EPROTOTYPE:
            case EPROTONOSUPPORT:
            case EAFNOSUPPORT:
                return -EC_ADDRESSTYPE_NOT_SUPPORTED;
            case ECONNREFUSED:
                return -EC_CONN_REFUSED;
            case ENETDOWN:
            case ENETUNREACH:
                return -EC_NET_UNREACHABLE;
            case EHOSTUNREACH:
                return -EC_HOST_UNREACHABLE;
            case EBADF:
            default:
                perror("socket/connect");
                return -EC_GENERAL_FAILURE;
        }
    }

    int af = SOCKADDR_UNION_AF(client_addr);
    if ( (af == AF_INET && client_addr->v4.sin_addr.s_addr != INADDR_ANY) ||
        (af == AF_INET6 && !IN6_IS_ADDR_UNSPECIFIED(&client_addr->v6.sin6_addr)) ) {
        if (connect(fd, (const struct sockaddr*)client_addr, sizeof(union sockaddr_union))) {
            perror("udp connect");
            return -1;
        }
        return fd;
    }

    struct addrinfo* addr;
    struct addrinfo hints = {
        .ai_flags = AI_PASSIVE,
        .ai_family = af,
        .ai_socktype = SOCK_DGRAM,
    };
    int ret = getaddrinfo(NULL, "0", &hints, &addr);
    if (0 != ret) {
        dprintf(2, "could not resolve to a local UDP address");
        return ret;
    }
    if (0 != bind(fd, addr->ai_addr, addr->ai_addrlen)) {
        perror("udplocal bind");
        freeaddrinfo(addr);
        return -1;
    }
    freeaddrinfo(addr);
    return fd;
}

static void* clientthread(void *data) {
    struct thread *t = data;
    t->state = SS_1_CONNECTED;
    unsigned char buf[1024];
    ssize_t n;
    int ret;
    // for CONNECT, this is target TCP address
    // for UDP ASSOCIATE, this is client UDP address
    union sockaddr_union address, local_addr;
    struct socks5_addrport requested_addr;

    enum authmethod am;
    while((n = recv(t->client.fd, buf, sizeof buf, 0)) > 0) {
        switch(t->state) {
            case SS_1_CONNECTED:
                am = check_auth_method(buf, n, &t->client);
                if(am == AM_NO_AUTH) t->state = SS_3_AUTHED;
                else if (am == AM_USERNAME) t->state = SS_2_NEED_AUTH;
                send_auth_response(t->client.fd, 5, am);
                if(am == AM_INVALID) goto breakloop;
                break;
            case SS_2_NEED_AUTH:
                ret = check_credentials(buf, n);
                send_auth_response(t->client.fd, 1, ret);
                if(ret != EC_SUCCESS)
                    goto breakloop;
                t->state = SS_3_AUTHED;
                if(auth_ips && !pthread_rwlock_wrlock(&auth_ips_lock)) {
                    if(!is_in_authed_list(&t->client.addr))
                        add_auth_ip(&t->client.addr);
                    pthread_rwlock_unlock(&auth_ips_lock);
                }
                break;
            case SS_3_AUTHED:
                (void)0;
                int cmd = 0;
                ret = parse_socks_request_header(buf, n, &cmd, &address, &requested_addr);
                if (ret != EC_SUCCESS)
                    goto breakloop;
                
                if (cmd == CONNECT) {
                    int64_t connection_id = next_connection_identifier();
                    ret = connect_socks_target(&address, &t->client);
                    if(ret < 0) {
                        emit_addrport_connection_event(
                            connection_id,
                            TWOSOCKS_CONNECTION_PROTOCOL_TCP,
                            TWOSOCKS_CONNECTION_ERROR,
                            &requested_addr,
                            ret * -1
                        );
                        send_error(t->client.fd, ret*-1);
                        goto breakloop;
                    }
                    int remotefd = ret;
                    socklen_t len = sizeof(union sockaddr_union);
                    if (getsockname(remotefd, (struct sockaddr*)&local_addr, &len)) {
                        emit_addrport_connection_event(
                            connection_id,
                            TWOSOCKS_CONNECTION_PROTOCOL_TCP,
                            TWOSOCKS_CONNECTION_ERROR,
                            &requested_addr,
                            EC_GENERAL_FAILURE
                        );
                        close(remotefd);
                        goto breakloop;
                    }
                    if (-1 == send_response(t->client.fd, EC_SUCCESS, &local_addr)) {
                        emit_addrport_connection_event(
                            connection_id,
                            TWOSOCKS_CONNECTION_PROTOCOL_TCP,
                            TWOSOCKS_CONNECTION_ERROR,
                            &requested_addr,
                            EC_GENERAL_FAILURE
                        );
                        close(remotefd);
                        goto breakloop;
                    }
                    emit_addrport_connection_event(
                        connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_TCP,
                        TWOSOCKS_CONNECTION_OPEN,
                        &requested_addr,
                        EC_SUCCESS
                    );
                    enum twosocks_connection_state final_state = copyloop(t->client.fd, remotefd);
                    emit_addrport_connection_event(
                        connection_id,
                        TWOSOCKS_CONNECTION_PROTOCOL_TCP,
                        final_state,
                        &requested_addr,
                        final_state == TWOSOCKS_CONNECTION_ERROR ? EC_GENERAL_FAILURE : EC_SUCCESS
                    );
                    close(remotefd);
                    goto breakloop;
                } else if (cmd == UDP_ASSOCIATE) {
                    int fd = udp_svc_setup(&address);
                    if(fd <= 0) {
                        send_error(t->client.fd, fd*-1);
                        goto breakloop;
                    }

                    if(populate_udp_response_addr(fd, t->client.fd, &local_addr)) {
                        close(fd);
                        goto breakloop;
                    }
                    if (-1 == send_response(t->client.fd, EC_SUCCESS, &local_addr)) {
                        close(fd);
                        goto breakloop;
                    }
                    if (CONFIG_LOG) {
                        char clientname[256];
                        int af = SOCKADDR_UNION_AF(&address);
                        void *ipdata = SOCKADDR_UNION_ADDRESS(&address);
                        unsigned short port_c = ntohs(SOCKADDR_UNION_PORT(&address));
                        inet_ntop(af, ipdata, clientname, sizeof clientname);
                        char udp_svc_name[256];
                        ipdata = SOCKADDR_UNION_ADDRESS(&local_addr);
                        unsigned int port_s = ntohs(SOCKADDR_UNION_PORT(&local_addr));
                        inet_ntop(af, ipdata, udp_svc_name, sizeof udp_svc_name);
                        dolog("client[%d] uses UDP address %s:%d, local UDP bind address is %s:%d\n", t->client.fd, clientname, port_c, 
                            udp_svc_name, port_s);
                    }
                    copy_loop_udp(t->client.fd, fd);
                    close(fd);
                    goto breakloop;
                } else {
                    // should not be here
                    abort();
                }
        }
    }
breakloop:

    close(t->client.fd);
    t->done = 1;

    return 0;
}

static void collect(sblist *threads) {
    size_t i;
    for(i=0;i<sblist_getsize(threads);) {
        struct thread* thread = *((struct thread**)sblist_get(threads, i));
        if(thread->done) {
            pthread_join(thread->pt, 0);
            sblist_delete(threads, i);
            free(thread);
        } else
            i++;
    }
}

static int usage(void) {
    dprintf(2,
        "MicroSocks SOCKS5 Server\n"
        "------------------------\n"
        "usage: microsocks -1 -q -i listenip -p port -u user -P password -b bindaddr\n"
        "all arguments are optional.\n"
        "by default listenip is 0.0.0.0 and port 1080.\n\n"
        "option -q disables logging.\n"
        "option -b specifies which ip outgoing connections are bound to\n"
        "option -1 activates auth_once mode: once a specific ip address\n"
        "authed successfully with user/pass, it is added to a whitelist\n"
        "and may use the proxy without auth.\n"
        "this is handy for programs like firefox that don't support\n"
        "user/pass auth. for it to work you'd basically make one connection\n"
        "with another program that supports it, and then you can use firefox too.\n"
    );
    return 1;
}

/* prevent username and password from showing up in top. */
static void zero_arg(char *s) {
    size_t i, l = strlen(s);
    for(i=0;i<l;i++) s[i] = 0;
}

int socks_main(int argc, char** argv) {
    int ch;
    const char *listenip = "0.0.0.0";
    unsigned port = 1080;
    while((ch = getopt(argc, argv, ":1qi:p:u:P:")) != -1) {
        switch(ch) {
            case '1':
                auth_ips = sblist_new(sizeof(union sockaddr_union), 8);
                break;
            case 'q':
                quiet = 1;
                break;
            case 'u':
                auth_user = strdup(optarg);
                zero_arg(optarg);
                break;
            case 'P':
                auth_pass = strdup(optarg);
                zero_arg(optarg);
                break;
            case 'i':
                listenip = optarg;
                break;
            case 'p':
                port = atoi(optarg);
                break;
            case ':':
                dprintf(2, "error: option -%c requires an operand\n", optopt);
                /* fall through */
            case '?':
                return usage();
        }
    }
    if((auth_user && !auth_pass) || (!auth_user && auth_pass)) {
        dprintf(2, "error: user and pass must be used together\n");
        return 1;
    }
    if(auth_ips && !auth_pass) {
        dprintf(2, "error: auth-once option must be used together with user/pass\n");
        return 1;
    }
    signal(SIGPIPE, SIG_IGN);
    struct server s;
    sblist *threads = sblist_new(sizeof (struct thread*), 8);
    if(server_setup(&s, listenip, port)) {
        perror("server_setup");
        return 1;
    }
    server = &s;

    while(1) {
        collect(threads);
        struct client c;
        struct thread *curr = malloc(sizeof (struct thread));
        if(!curr) goto oom;
        curr->done = 0;
        if(server_waitclient(&s, &c)) {
            dolog("failed to accept connection\n");
            free(curr);
            usleep(FAILURE_TIMEOUT);
            continue;
        }
        curr->client = c;
        if(!sblist_add(threads, &curr)) {
            close(curr->client.fd);
            free(curr);
            oom:
            dolog("rejecting connection due to OOM\n");
            usleep(FAILURE_TIMEOUT); /* prevent 100% CPU usage in OOM situation */
            continue;
        }
        pthread_attr_t *a = 0, attr;
        if(pthread_attr_init(&attr) == 0) {
            a = &attr;
            pthread_attr_setstacksize(a, THREAD_STACK_SIZE);
        }
        if(pthread_create(&curr->pt, a, clientthread, curr) != 0) {
            dolog("pthread_create failed. OOM?\n");
            close(curr->client.fd);
            sblist_delete(threads, sblist_getsize(threads) - 1);
            free(curr);
            usleep(FAILURE_TIMEOUT);
        }
        if(a) pthread_attr_destroy(&attr);
    }
}
