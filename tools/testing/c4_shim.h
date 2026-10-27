/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Minimal test doubles for C4. Units and fields follow Linux 6.12. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#define U8_MAX UINT8_MAX
#define U32_MAX UINT32_MAX
#define U64_MAX UINT64_MAX
#define USEC_PER_SEC 1000000U
#define ICSK_CA_PRIV_SIZE 208
#define __read_mostly
#define __init
#define __exit
#define THIS_MODULE NULL
#define TCP_CONG_NON_RESTRICTED 1
#define TCP_INFINITE_SSTHRESH 0x7fffffff
#define SK_PACING_NONE 0
#define SK_PACING_NEEDED 1
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define cmpxchg(p, old, value) ((*(p) == (old)) ? (*(p) = (value), (old)) : *(p))
#define min(a, b) ({ __auto_type _a = (a); __auto_type _b = (b); _a < _b ? _a : _b; })
#define max(a, b) ({ __auto_type _a = (a); __auto_type _b = (b); _a > _b ? _a : _b; })
#define min_t(t, a, b) min((t)(a), (t)(b))
#define max_t(t, a, b) max((t)(a), (t)(b))
#define clamp_t(t, a, lo, hi) min_t(t, max_t(t, a, lo), hi)
#define DIV_ROUND_UP_ULL(n, d) (((n) + (d) - 1) / (d))
#define BUILD_BUG_ON(x) _Static_assert(!(x), #x)
#define WARN_ON_ONCE(x) (x)
#define MODULE_AUTHOR(x)
#define MODULE_LICENSE(x)
#define MODULE_DESCRIPTION(x)
#define module_init(x)
#define module_exit(x)

enum { TCP_CA_Open, TCP_CA_Disorder, TCP_CA_CWR, TCP_CA_Recovery, TCP_CA_Loss };
enum tcp_ca_event { CA_EVENT_TX_START, CA_EVENT_CWND_RESTART, CA_EVENT_LOSS };
struct tcp_sock {
	u32 delivered, delivered_ce, lost, mss_cache, snd_cwnd, snd_cwnd_clamp;
	u32 snd_ssthresh, prior_cwnd, prior_ssthresh, srtt_us;
	u32 prr_delivered, prr_out, in_flight;
	u64 tcp_wstamp_ns, tcp_mstamp;
	bool cwnd_limited;
};
struct inet_connection_sock { u8 icsk_ca_state; };
struct sock {
	struct tcp_sock tp;
	struct inet_connection_sock icsk;
	u64 sk_pacing_rate, sk_max_pacing_rate;
	int sk_pacing_status;
	union { u64 align; unsigned char data[ICSK_CA_PRIV_SIZE]; } ca;
};
struct rate_sample {
	int delivered;
	long interval_us, rtt_us;
	u32 prior_delivered, prior_in_flight, acked_sacked;
	int losses;
	bool is_ack_delayed, is_app_limited, is_retrans;
};
struct tcp_congestion_ops {
	int flags;
	const char *name;
	void *owner;
	void (*init)(struct sock *);
	u32 (*ssthresh)(struct sock *);
	u32 (*undo_cwnd)(struct sock *);
	void (*set_state)(struct sock *, u8);
	void (*cwnd_event)(struct sock *, enum tcp_ca_event);
	void (*cong_control)(struct sock *, u32, int, const struct rate_sample *);
};
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk(sk) (&(sk)->icsk)
#define inet_csk_ca(sk) ((void *)(sk)->ca.data)
static u64 div64_u64(u64 a, u64 b) { return a / b; }
static u64 div_u64(u64 a, u32 b) { return a / b; }
static u64 mul_u64_u32_div(u64 a, u32 b, u32 d) { return (__uint128_t)a * b / d; }
static u64 mul_u64_u64_div_u64(u64 a, u64 b, u64 d) { return (__uint128_t)a * b / d; }
static bool before(u32 a, u32 b) { return (int32_t)(a - b) < 0; }
static u32 tcp_snd_cwnd(const struct tcp_sock *tp) { return tp->snd_cwnd; }
static void tcp_snd_cwnd_set(struct tcp_sock *tp, u32 cwnd) { tp->snd_cwnd = cwnd; }
static u32 tcp_packets_in_flight(const struct tcp_sock *tp) { return tp->in_flight; }
static bool tcp_in_cwnd_reduction(const struct sock *sk)
{
	return sk->icsk.icsk_ca_state == TCP_CA_CWR || sk->icsk.icsk_ca_state == TCP_CA_Recovery;
}
static bool tcp_is_cwnd_limited(const struct sock *sk) { return sk->tp.cwnd_limited; }
static u64 tcp_clock_ns(void) { return 123456789; }
static void tcp_slow_start(struct tcp_sock *tp, u32 acked)
{
	tp->snd_cwnd = min(tp->snd_cwnd + acked, min(tp->snd_ssthresh, tp->snd_cwnd_clamp));
}
static void tcp_cwnd_reduction(struct sock *sk, int acked, int lost, int flag)
{
	/* Tests check callback ownership. Module tests exercise the inline PRR. */
	sk->tp.snd_cwnd = 7;
}
static int tcp_register_congestion_control(struct tcp_congestion_ops *ops) { return 0; }
static void tcp_unregister_congestion_control(struct tcp_congestion_ops *ops) { }
