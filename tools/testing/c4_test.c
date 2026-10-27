/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "c4_shim.h"
#include "tcp_c4.c"

static struct sock fresh(void)
{
	struct sock sk = {0};
	sk.tp.mss_cache = 1000;
	sk.tp.snd_cwnd = 10;
	sk.tp.snd_cwnd_clamp = 1000000;
	sk.tp.srtt_us = 80000;
	sk.tp.tcp_mstamp = 2000000;
	sk.sk_max_pacing_rate = 1000000000;
	c4_init(&sk);
	return sk;
}

static void trim_two_cycles(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	c4_enter(&sk, C4_PROBING);
	ca->round_peak_rate = 800000;
	c4_finish_round(&sk, 0);
	ca->round_peak_rate = 700000;
	c4_finish_round(&sk, 0);
	assert(ca->nominal_rate == 800000);
	/* A single low cycle must not replace a previous higher peak. */
	c4_enter(&sk, C4_PROBING);
	ca->round_peak_rate = 500000;
	c4_finish_round(&sk, 0);
	ca->round_peak_rate = 400000;
	c4_finish_round(&sk, 0);
	assert(ca->nominal_rate == 800000);
	c4_enter(&sk, C4_PROBING);
	ca->round_peak_rate = 400000;
	c4_finish_round(&sk, 0);
	ca->round_peak_rate = 300000;
	c4_finish_round(&sk, 0);
	assert(ca->nominal_rate == 500000);
}

static void trim_guards(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 1000;
	sk.tp.srtt_us = 4000; /* Linux stores SRTT in microseconds times eight. */
	c4_enter(&sk, C4_PROBING);
	ca->round_peak_rate = 300000;
	c4_finish_round(&sk, 0);
	c4_finish_round(&sk, 0);
	assert(ca->nominal_rate == 1000000);
	ca->max_rtt_us = 10000;
	sk.tp.srtt_us = 80000;
	/* Empty/app-limited cycles must not drive nominal rate to zero. */
	c4_enter(&sk, C4_PROBING);
	c4_finish_round(&sk, 0);
	c4_finish_round(&sk, 0);
	assert(ca->nominal_rate == 1000000);
}

static void drain_startup_and_push(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->initial_cwnd = 100;
	ca->max_rtt_us = 10000;
	ca->prior_rate = ca->nominal_rate;
	ca->rounds_without_growth = 2;
	ca->round_peak_rate = 1000000;
	c4_finish_round(&sk, 0);
	assert(ca->mode == C4_RECOVERY);
	assert(ca->gain_q10 == 758);
	assert(ca->max_rtt_us == 50000); /* 100 packets * 1000 bytes / 2 / rate. */
	c4_finish_round(&sk, 0);
	c4_enter(&sk, C4_PUSHING);
	ca->round_peak_rate = ca->nominal_rate;
	c4_finish_round(&sk, 0);
	assert(ca->mode == C4_RECOVERY && ca->gain_q10 == 758);
	/* Repeated loss must not weaken 758/1024 draining to 896/1024. */
	c4_notify_congestion(&sk, C4_CONGESTION_LOSS, 0, C4_Q10, false);
	assert(ca->gain_q10 == 758);
	u32 backlog = ca->backlog_q10;
	c4_finish_round(&sk, 0);
	assert(ca->backlog_q10 == backlog - 266);
	ca->backlog_q10 = UINT32_MAX;
	c4_enter(&sk, C4_PUSHING);
	c4_finish_round(&sk, 0);
	assert(ca->backlog_q10 == UINT32_MAX);
}

static void small_rtt_and_ecn(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 1000;
	ca->initial_cwnd = 100;
	ca->prior_rate = ca->nominal_rate;
	ca->rounds_without_growth = 2;
	ca->round_peak_rate = 1000000;
	sk.tp.srtt_us = 4000;
	c4_finish_round(&sk, 0);
	assert(ca->gain_q10 == 960);
	c4_enter(&sk, C4_PUSHING);
	c4_notify_congestion(&sk, C4_CONGESTION_ECN, 0, C4_Q10, false);
	assert(ca->gain_q10 == 960);
}

static void jitter_reentry(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = 10, .interval_us = 100000,
		.rtt_us = 100000, .prior_delivered = 100 };
	ca->nominal_rate = 100000;
	ca->max_rtt_us = 100000;
	ca->min_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	c4_enter(&sk, C4_RECOVERY);
	c4_finish_round(&sk, 0); /* Starts the one-second re-entry guard. */
	sk.tp.tcp_mstamp += 1000000;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->mode != C4_INITIAL);
	sk.tp.tcp_mstamp += 1;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->mode == C4_INITIAL);
	assert(ca->max_rtt_us == 10000);
	assert(ca->initial_cwnd == 1); /* nominal-rate BDP floor, not old cwnd. */
}

static void reentry_current_ack_rate(void)
{
	const u32 rates[] = { 999999, 1000000, 1000001, 10000000 };

	for (unsigned int recovery = 0; recovery < 2; recovery++) {
		for (unsigned int i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
			struct sock sk = fresh();
			struct c4 *ca = c4_ca(&sk);
			struct rate_sample rs = { .delivered = 1, .interval_us = 1000000,
				.prior_delivered = 100, .acked_sacked = 1 };

			sk.tp.mss_cache = rates[i];
			ca->mss_cache = rates[i];
			ca->nominal_rate = 100000;
			ca->max_rtt_us = 100000;
			ca->min_rtt_us = 10000;
			c4_enter(&sk, C4_CRUISING);
			if (recovery)
				c4_enter(&sk, C4_RECOVERY);
			ca->initial_last_time = sk.tp.tcp_mstamp - 1000001;
			/* The completed round and current ACK have distinct peaks. */
			ca->round_peak_rate = 80000;
			sk.tp.delivered = 101;
			c4_cong_control(&sk, 0, 0, &rs);
			if ((ca->mode == C4_INITIAL) != (rates[i] < 1000000))
				fprintf(stderr, "reentry rate=%u recovery=%u mode=%u nominal=%llu\n",
					rates[i], recovery, ca->mode, (unsigned long long)ca->nominal_rate);
			if (rates[i] < 1000000) {
				assert(ca->mode == C4_INITIAL && ca->gain_q10 == 2048);
			} else if (recovery) {
				assert(ca->mode == C4_CRUISING && ca->gain_q10 == 1024);
				assert(ca->recent_rate == 0);
				assert(ca->previous_rate == 80000);
			} else {
				assert(ca->mode == C4_PROBING && ca->gain_q10 == 1120);
				assert(ca->recent_rate == 80000);
			}
			assert(ca->nominal_rate == rates[i]);
			assert(ca->round_peak_rate == rates[i]);
		}
	}
	/* App-limited bandwidth is not admissible evidence for the rate gate. */
	for (unsigned int peak = 0; peak < 2; peak++) {
		struct sock app = fresh();
		struct c4 *state = c4_ca(&app);
		struct rate_sample limited = { .delivered = 100, .interval_us = 10000,
			.prior_delivered = 100, .is_app_limited = true };

		state->nominal_rate = 100000;
		state->max_rtt_us = 100000;
		state->min_rtt_us = 10000;
		c4_enter(&app, C4_CRUISING);
		state->initial_last_time = app.tp.tcp_mstamp - 1000001;
		state->round_peak_rate = peak ? 100000 : 0;
		app.tp.delivered = 200;
		c4_cong_control(&app, 0, 0, &limited);
		assert(state->mode == (peak ? C4_INITIAL : C4_CRUISING));
		assert(state->nominal_rate == 100000 && state->round_peak_rate == 0);
	}
	/* Review reproduction: 100 packets * MSS1000 / 10000us = 10 MB/s. */
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = 100, .interval_us = 10000,
		.prior_delivered = 100, .acked_sacked = 100 };
	ca->nominal_rate = 100000;
	ca->max_rtt_us = 100000;
	ca->min_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	ca->round_peak_rate = 100000;
	ca->initial_last_time = sk.tp.tcp_mstamp - 1000001;
	sk.tp.delivered = 200;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->mode == C4_PROBING && ca->gain_q10 == 1120);
	assert(ca->nominal_rate == 10000000 && ca->round_peak_rate == 10000000);
	assert(ca->recent_rate == 100000); /* No early attribution to the old cycle. */
}

static void recovery_reentry_and_suppression(void)
{
	/* Recovery re-entry requires strictly more than one second. */
	struct sock timed = fresh();
	struct c4 *state = c4_ca(&timed);
	struct rate_sample low = { .delivered = 1, .interval_us = 10000,
		.prior_delivered = 100 };
	state->nominal_rate = 100000;
	state->max_rtt_us = 100000;
	state->min_rtt_us = 10000;
	c4_enter(&timed, C4_CRUISING);
	c4_enter(&timed, C4_RECOVERY);
	state->initial_last_time = timed.tp.tcp_mstamp - 1000000;
	state->round_peak_rate = 100000;
	timed.tp.delivered = 101;
	c4_cong_control(&timed, 0, 0, &low);
	assert(state->mode == C4_CRUISING && state->gain_q10 == 1024);
	assert(state->initial_last_time == 1000000);
	for (unsigned int congested = 0; congested < 2; congested++) {
		struct sock sk = fresh();
		struct c4 *ca = c4_ca(&sk);
		struct rate_sample rs = { .delivered = 100, .interval_us = 10000,
			.prior_delivered = 100, .acked_sacked = 1 };

		ca->nominal_rate = 100000;
		ca->max_rtt_us = 100000;
		ca->min_rtt_us = 10000;
		c4_enter(&sk, C4_CRUISING);
		c4_enter(&sk, C4_RECOVERY);
		ca->round_peak_rate = 100000;
		ca->initial_last_time = sk.tp.tcp_mstamp - 1000001;
		if (congested)
			ca->state_flags |= C4_STATE_CONGESTION;
		sk.tp.delivered = 101;
		if (!congested) {
			rs.delivered = 1;
			rs.interval_us = 10000; /* 100 kB/s: eligible for recovery reentry. */
		}
		c4_cong_control(&sk, 0, 0, &rs);
		assert(ca->mode == C4_INITIAL && ca->gain_q10 == 2048);
		assert(ca->nominal_rate == 100000);
		assert(ca->max_rtt_us == 10000 && ca->initial_cwnd == 1);
		assert(ca->round_peak_rate == (congested ? 10000000 : 100000));
		assert(ca->initial_last_time == 0);
	}
}

static void congestion_cycle_ack(struct sock *sk, u32 delivered,
				u32 prior, int sample_packets, long interval, long rtt)
{
	struct rate_sample rs = { .delivered = sample_packets, .interval_us = interval,
		.rtt_us = rtt, .prior_delivered = prior,
		.acked_sacked = delivered - sk->tp.delivered };

	sk->tp.delivered = delivered;
	c4_cong_control(sk, 0, 0, &rs);
}

static void two_congestion_cycles_ack_sequence(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);

	sk.tp.delivered = 100;
	ca->nominal_rate = 1000000;
	ca->min_rtt_us = ca->max_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	congestion_cycle_ack(&sk, 108, 100, 8, 10000, 10000);
	assert(ca->mode == C4_CRUISING && ca->cruise_rounds == 1);
	assert(ca->round_peak_rate == 800000 && ca->recent_rate == 0);
	assert(ca->next_round_delivered == 108);
	/* One cruise round now advances to probing. */
	congestion_cycle_ack(&sk, 116, 108, 8, 10000, 10000);
	assert(ca->mode == C4_PROBING && ca->gain_q10 == 1120);
	assert(ca->recent_rate == 800000 && ca->next_round_delivered == 116);
	/* The following round evaluates the probe and enters recovery. */
	congestion_cycle_ack(&sk, 124, 116, 8, 10000, 10000);
	assert(ca->mode == C4_RECOVERY && ca->gain_q10 == 960);
	assert(ca->round_peak_rate == 800000 && ca->next_round_delivered == 124);
	congestion_cycle_ack(&sk, 125, 101, 24, 30000, 30000);
	assert(ca->mode == C4_RECOVERY && ca->gain_q10 == 960);
	assert(ca->nominal_rate == 1000000 && ca->recent_rate == 800000);
	assert(ca->round_peak_rate == 800000 && ca->next_round_delivered == 124);
	congestion_cycle_ack(&sk, 126, 119, 7, 10000, 10000);
	assert(ca->mode == C4_RECOVERY && ca->round_peak_rate == 800000);
	assert(ca->recent_rate == 800000 && ca->recent_congestions == 0);
	congestion_cycle_ack(&sk, 130, 126, 4, 10000, 10000);
	assert(ca->mode == C4_CRUISING && ca->gain_q10 == 1024);
	assert(ca->nominal_rate == 800000 && ca->recent_congestions == 0);
	assert(ca->previous_rate == 800000 && ca->recent_rate == 0);
	assert(ca->round_peak_rate == 400000 && ca->next_round_delivered == 130);
	assert(!(ca->state_flags & C4_STATE_CONGESTION));
	assert(ca->loss_ewma_q16 == 0 && ca->ecn_alpha_q10 == 0);
	congestion_cycle_ack(&sk, 135, 130, 5, 10000, 10000);
	assert(ca->mode == C4_PROBING && ca->gain_q10 == 1120);
	assert(ca->recent_rate == 400000 && ca->round_peak_rate == 500000);
	congestion_cycle_ack(&sk, 140, 135, 5, 10000, 10000);
	assert(ca->mode == C4_RECOVERY && ca->gain_q10 == 960);
	assert(ca->round_peak_rate == 500000 && ca->recent_congestions == 0);
	congestion_cycle_ack(&sk, 141, 126, 15, 30000, 30000);
	assert(ca->mode == C4_RECOVERY && ca->gain_q10 == 960);
	assert(ca->nominal_rate == 800000 && ca->recent_congestions == 0);
	assert(ca->recent_rate == 500000 && ca->round_peak_rate == 500000);
	assert(ca->next_round_delivered == 140);
	congestion_cycle_ack(&sk, 142, 138, 4, 10000, 10000);
	assert(ca->mode == C4_RECOVERY && ca->round_peak_rate == 500000);
	assert(ca->recent_rate == 500000 && ca->recent_congestions == 0);
	congestion_cycle_ack(&sk, 145, 142, 3, 10000, 10000);
	assert(ca->mode == C4_CRUISING && ca->gain_q10 == 1024);
	assert(ca->nominal_rate == 800000 && ca->recent_congestions == 0);
	assert(ca->previous_rate == 500000 && ca->recent_rate == 0);
	assert(ca->round_peak_rate == 300000 && ca->next_round_delivered == 145);
	assert(!(ca->state_flags & C4_STATE_CONGESTION));
	assert(ca->loss_ewma_q16 == 0 && ca->ecn_alpha_q10 == 0);
	assert(sk.sk_pacing_rate == 800000 && sk.tp.snd_cwnd == 10);
}

static void raw_srtt_boundaries(void)
{
	const u32 srtts[] = { 999, 1000, 1001, 2000, 0 };

	for (unsigned int i = 0; i < sizeof(srtts) / sizeof(srtts[0]); i++) {
		struct sock sk = fresh();
		struct c4 *ca = c4_ca(&sk);

		sk.tp.srtt_us = srtts[i] * 8;
		ca->nominal_rate = 1000000;
		ca->max_rtt_us = 1000;
		ca->backlog_q10 = 129;
		c4_enter(&sk, C4_PROBING);
		c4_enter(&sk, C4_RECOVERY);
		assert(ca->gain_q10 == (srtts[i] < 1000 ? 960 : 758));
		assert(ca->backlog_q10 == (srtts[i] < 1000 ? 0 : 129));
		ca->round_peak_rate = 500000;
		ca->previous_rate = 600000;
		c4_finish_round(&sk, 0);
		assert(ca->nominal_rate == (srtts[i] > 1000 ? 600000 : 1000000));
		assert(ca->backlog_q10 == 0);
		assert(ca->previous_rate == 500000);
		assert(ca->mode == C4_CRUISING);
	}
}

static void retransmitted_samples_are_not_model_evidence(void)
{
	const bool recovery_events[] = { false, true };

	for (unsigned int i = 0; i < sizeof(recovery_events) / sizeof(recovery_events[0]); i++) {
		struct sock sk = fresh();
		struct c4 *ca = c4_ca(&sk);
		struct rate_sample rs = {
			.delivered = 10, .interval_us = 10000, .rtt_us = 30000,
			.prior_delivered = UINT32_MAX, .acked_sacked = 10,
			.losses = recovery_events[i] ? 2 : 0, .is_retrans = true,
		};

		ca->nominal_rate = 100000;
		ca->min_rtt_us = 20000;
		ca->max_rtt_us = 30000;
		ca->round_peak_rate = 90000;
		ca->next_round_delivered = 100;
		sk.tp.delivered = 110;
		c4_enter(&sk, C4_INITIAL);
		ca->round_peak_rate = 90000;
		ca->min_rtt_us = 20000;
		ca->max_rtt_us = 30000;
		ca->next_round_delivered = 100;
		ca->initial_cwnd = sk.tp.snd_cwnd;
		c4_cong_control(&sk, 0, 0, &rs);
		assert(ca->nominal_rate == 100000);
		assert(ca->round_peak_rate == 90000);
		assert(ca->min_rtt_us == 20000 && ca->max_rtt_us == 30000);
		assert(ca->next_round_delivered == 100);
		assert(ca->mode == C4_INITIAL && ca->initial_cwnd == sk.tp.snd_cwnd);
	}

	/* ACK compression remains valid evidence when the sample is not retransmitted. */
	struct sock compressed = fresh();
	struct c4 *state = c4_ca(&compressed);
	struct rate_sample rs = { .delivered = 20, .interval_us = 1000,
		.rtt_us = 1000, .prior_delivered = UINT32_MAX };

	state->nominal_rate = 100000;
	state->max_rtt_us = 10000;
	compressed.tp.delivered = 20;
	c4_cong_control(&compressed, 0, 0, &rs);
	assert(state->round_peak_rate == 20000000);
	assert(state->nominal_rate == 20000000);
}

static void mss_change_quarantines_rate_samples(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = 10, .interval_us = 10000,
		.prior_delivered = UINT32_MAX };

	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	ca->round_peak_rate = 900000;
	sk.tp.in_flight = 3;
	sk.tp.mss_cache = 1200;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->nominal_rate == 1000000);
	assert(ca->round_peak_rate == 0);
	assert(ca->state_flags & C4_STATE_MSS_QUARANTINE);

	/* Old-MSS delivery cannot end quarantine while packets remain in flight. */
	sk.tp.in_flight = 0;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(!(ca->state_flags & C4_STATE_MSS_QUARANTINE));
	assert(ca->nominal_rate == 1000000 && ca->round_peak_rate == 0);
}

static void undo_restores_round_and_rtt_history(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);

	ca->mode = C4_PUSHING;
	ca->gain_q10 = C4_GAIN_PUSH;
	ca->nominal_rate = 1000000;
	ca->prior_rate = 900000;
	ca->recent_rate = 800000;
	ca->previous_rate = 700000;
	ca->round_peak_rate = 600000;
	ca->next_round_delivered = 123;
	ca->min_rtt_us = 8000;
	ca->max_rtt_us = 12000;
	ca->era_min_rtt_us = 9000;
	ca->era_max_rtt_us = 11000;
	ca->startup_credit_q9 = 37;
	ca->cruise_rounds = 1;
	ca->rounds_without_growth = 2;
	ca->probe_succeeded = 1;
	ca->recent_congestions = 2;
	ca->loss_ewma_q16 = 321;
	ca->ecn_alpha_q10 = 123;
	ca->state_flags |= C4_STATE_CONGESTION | C4_STATE_RTT_DELAYED_BASE;
	c4_notify_congestion(&sk, C4_CONGESTION_LOSS, 0, C4_Q10, true);

	ca->round_peak_rate = 1;
	ca->next_round_delivered = 999;
	ca->min_rtt_us = 1;
	ca->max_rtt_us = 2;
	ca->era_min_rtt_us = 3;
	ca->era_max_rtt_us = 4;
	ca->startup_credit_q9 = 0;
	ca->cruise_rounds = 0;
	ca->rounds_without_growth = 0;
	ca->probe_succeeded = 0;
	ca->recent_congestions = 0;
	ca->loss_ewma_q16 = 0;
	ca->ecn_alpha_q10 = 0;
	c4_undo_cwnd(&sk);
	assert(ca->round_peak_rate == 600000);
	assert(ca->next_round_delivered == 123);
	assert(ca->min_rtt_us == 8000 && ca->max_rtt_us == 12000);
	assert(ca->era_min_rtt_us == 9000 && ca->era_max_rtt_us == 11000);
	assert(ca->startup_credit_q9 == 37 && ca->cruise_rounds == 1);
	assert(ca->rounds_without_growth == 2 && ca->probe_succeeded == 1);
	assert(ca->recent_congestions == 2);
	assert(ca->loss_ewma_q16 == 321 && ca->ecn_alpha_q10 == 123);
	assert(ca->state_flags & C4_STATE_CONGESTION);
	assert(ca->state_flags & C4_STATE_RTT_DELAYED_BASE);
}

static void invalid_and_congested_samples(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = -1, .interval_us = -1,
		.prior_delivered = 100 };
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	ca->loss_ewma_q16 = 100;
	ca->ecn_alpha_q10 = 50;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->cruise_rounds == 1);
	assert(ca->loss_ewma_q16 == 100 && ca->ecn_alpha_q10 == 50);
	c4_notify_congestion(&sk, C4_CONGESTION_DELAY, 1000, C4_Q10, false);
	u64 reduced = ca->nominal_rate;
	rs.delivered = 100;
	rs.interval_us = 1000;
	rs.prior_delivered = UINT32_MAX; /* Remain within this recovery round. */
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->mode == C4_RECOVERY && ca->nominal_rate == reduced);
	rs.prior_delivered = 100; /* Recovery exit ACK still measures the old phase. */
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->mode == C4_CRUISING && ca->nominal_rate == reduced);
}

static void app_limited_and_cwr_events(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = 10, .interval_us = 10000,
		.prior_delivered = 100, .is_app_limited = true };
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	c4_cong_control(&sk, 0, 0, &rs);
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->nominal_rate == 1000000 && ca->round_peak_rate == 0);
	assert(ca->cruise_rounds == 1);
	/* A negotiated ECN CWR is classified separately from transient TLP loss. */
	c4_set_state(&sk, TCP_CA_CWR);
	sk.icsk.icsk_ca_state = TCP_CA_CWR;
	sk.tp.prior_cwnd = 10;
	sk.tp.snd_ssthresh = 7;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->nominal_rate == 937500);
	assert(ca->state_flags & C4_STATE_CONGESTION);
	sk = fresh();
	ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	c4_enter(&sk, C4_CRUISING);
	c4_set_state(&sk, TCP_CA_CWR);
	sk.icsk.icsk_ca_state = TCP_CA_CWR;
	c4_set_state(&sk, TCP_CA_Open);
	sk.icsk.icsk_ca_state = TCP_CA_Open;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->nominal_rate < 937500);
	assert(!(ca->state_flags & C4_STATE_CWR_PENDING));
}

static void startup_fractional_ack_growth(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .delivered = 2, .interval_us = 20000,
		.prior_delivered = UINT32_MAX, .acked_sacked = 2 };
	sk.tp.cwnd_limited = true;
	ca->nominal_rate = 100000;
	ca->max_rtt_us = 10000;
	ca->rounds_without_growth = 1;
	for (int i = 0; i < 4; i++)
		c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->initial_cwnd == 11);
	ca->rounds_without_growth = 2;
	for (int i = 0; i < 32; i++)
		c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->initial_cwnd == 12);
	/* Startup re-entry owns its slow-start threshold after completed recovery. */
	sk.tp.snd_ssthresh = sk.tp.snd_cwnd;
	c4_enter(&sk, C4_INITIAL);
	assert(sk.tp.snd_ssthresh == TCP_INFINITE_SSTHRESH);
	/* Floor growth is a control change even if the TCP clamp prevents growth. */
	sk.tp.snd_cwnd = sk.tp.snd_cwnd_clamp = 20;
	ca->initial_cwnd = 19;
	ca->nominal_rate = 100000;
	ca->max_rtt_us = 10000;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(ca->initial_cwnd == 20 && sk.tp.snd_cwnd == 20);
}

static void startup_undo_and_boundaries(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	ca->nominal_rate = 1000000;
	ca->max_rtt_us = 10000;
	ca->initial_cwnd = 100;
	ca->backlog_q10 = 17;
	ca->recent_rate = 500000;
	ca->previous_rate = 600000;
	ca->initial_last_time = 1234;
	c4_notify_congestion(&sk, C4_CONGESTION_LOSS, 0, C4_Q10, true);
	assert(ca->max_rtt_us != 10000);
	c4_undo_cwnd(&sk);
	assert(ca->max_rtt_us == 10000 && ca->backlog_q10 == 17);
	assert(ca->recent_rate == 500000 && ca->previous_rate == 600000);
	assert(ca->initial_last_time == 1234 && ca->mode == C4_INITIAL);
	struct rate_sample extreme = { .delivered = INT_MAX, .interval_us = 1 };
	sk.tp.mss_cache = UINT32_MAX;
	assert(c4_sample_rate(&sk.tp, &extreme) <= C4_MAX_RATE);
	sk.tp.mss_cache = 1000;
	/* Exactly 1 ms must not inherit the sub-ms exception from a clamped RTT. */
	sk.tp.srtt_us = 8000;
	ca->max_rtt_us = 1000;
	ca->backlog_q10 = 129;
	c4_enter(&sk, C4_PUSHING);
	c4_enter(&sk, C4_RECOVERY);
	assert(ca->gain_q10 == 758);
	ca->backlog_q10 = 65;
	c4_enter(&sk, C4_PROBING);
	c4_enter(&sk, C4_RECOVERY);
	assert(ca->gain_q10 == 896);
	ca->backlog_q10 = 64;
	c4_enter(&sk, C4_PROBING);
	c4_enter(&sk, C4_RECOVERY);
	assert(ca->gain_q10 == 960);
	/* A nonzero backlog does not prevent recovery exit in upstream C4. */
	ca->backlog_q10 = 1000;
	c4_finish_round(&sk, 0);
	assert(ca->mode == C4_CRUISING && ca->gain_q10 == 1024 && ca->backlog_q10 == 936);
}

static void retained_linux_contracts(void)
{
	struct sock sk = fresh();
	struct c4 *ca = c4_ca(&sk);
	struct rate_sample rs = { .rtt_us = 30000, .is_ack_delayed = true };
	assert(sizeof(*ca) <= 208);
	assert(ca->nominal_rate == 0 && ca->gain_q10 == 2048);
	assert(sk.sk_pacing_status == SK_PACING_NEEDED);
	c4_update_rtt(ca, &rs);
	assert(ca->min_rtt_us == 30000);
	rs.is_ack_delayed = false;
	rs.rtt_us = 10000;
	c4_update_rtt(ca, &rs);
	assert(ca->min_rtt_us == 10000 && ca->max_rtt_us == 10000);
	rs.rtt_us = 0;
	c4_update_rtt(ca, &rs);
	assert(ca->min_rtt_us == 10000);
	ca->nominal_rate = 1000000;
	c4_enter(&sk, C4_PUSHING);
	c4_notify_congestion(&sk, C4_CONGESTION_LOSS, 0, C4_Q10, true);
	assert(ca->mode == C4_RECOVERY);
	c4_undo_cwnd(&sk);
	assert(ca->mode == C4_PUSHING && ca->nominal_rate == 1000000);
	/* PRR and TCP Loss own cwnd, not C4's BDP calculation. */
	sk.icsk.icsk_ca_state = TCP_CA_Loss;
	sk.tp.snd_cwnd = 3;
	c4_cong_control(&sk, 0, 0, &rs);
	assert(sk.tp.snd_cwnd == 3);
	sk.icsk.icsk_ca_state = TCP_CA_Recovery;
	sk.tp.prior_cwnd = 10;
	sk.tp.snd_ssthresh = 7;
	sk.tp.in_flight = 8;
	rs.acked_sacked = 1;
	c4_cong_control(&sk, 0, 0, &rs);
#ifdef MODULE
	assert(sk.tp.prr_delivered == 1);
#else
	assert(sk.tp.snd_cwnd == 7);
#endif
	sk.icsk.icsk_ca_state = TCP_CA_Open;
	c4_cwnd_event(&sk, CA_EVENT_CWND_RESTART);
	assert(sk.tp.tcp_wstamp_ns == tcp_clock_ns());
	/* Counter wrapping remains modular and bounded. */
	ca->old_delivered = UINT32_MAX - 1;
	ca->old_lost = UINT32_MAX;
	sk.tp.delivered = 2;
	sk.tp.lost = 0;
	c4_update_loss(&sk);
	c4_update_ecn(&sk);
	assert(ca->loss_ewma_q16 <= 65536 && ca->ecn_alpha_q10 <= 1024);
	ca->nominal_rate = 1000000000000ULL;
	ca->max_rtt_us = UINT32_MAX;
	sk.sk_max_pacing_rate = 1000000000;
	c4_apply_control(&sk);
	assert(sk.sk_pacing_rate <= sk.sk_max_pacing_rate);
	assert(sk.tp.snd_cwnd <= sk.tp.snd_cwnd_clamp);
	c4_init(&sk);
	assert(ca->nominal_rate == 0 && ca->prior_rate == 0);
}

int main(void)
{
	trim_two_cycles();
	trim_guards();
	drain_startup_and_push();
	small_rtt_and_ecn();
	jitter_reentry();
	reentry_current_ack_rate();
	recovery_reentry_and_suppression();
	raw_srtt_boundaries();
	retransmitted_samples_are_not_model_evidence();
	mss_change_quarantines_rate_samples();
	undo_restores_round_and_rtt_history();
	two_congestion_cycles_ack_sequence();
	invalid_and_congested_samples();
	app_limited_and_cwr_events();
	startup_fractional_ack_growth();
	startup_undo_and_boundaries();
	retained_linux_contracts();
	printf("C4 behavioral checks passed (%s, state %zu bytes)\n",
#ifdef MODULE
	       "module",
#else
	       "built-in",
#endif
	       sizeof(struct c4));
	return 0;
}
