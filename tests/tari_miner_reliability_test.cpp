// GPU-independent regressions for miner reliability policy.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "../tari_miner_reliability.h"

#include <cstdio>
#include <limits>
#include <string>

static int failures = 0;

static void check(bool condition, const char *name) {
    std::printf("  [%s] %s\n", condition ? "PASS" : "FAIL", name);
    if (!condition) failures++;
}

static void test_wallet_validation() {
    std::puts("Wallet validation:");
    const std::string standard_address(91, '1');
    check(tari_miner::validate_wallet(standard_address) ==
              tari_miner::WalletValidationError::None,
          "Base58 address is accepted");
    check(tari_miner::validate_wallet("custom-pool-login") ==
              tari_miner::WalletValidationError::None,
          "custom pool login format is accepted");
    check(tari_miner::validate_wallet("00aabbccddeeff") ==
              tari_miner::WalletValidationError::None,
          "hex address format is accepted");
    check(tari_miner::validate_wallet("\xf0\x9f\x90\xa2\xf0\x9f\x8c\x88") ==
              tari_miner::WalletValidationError::None,
          "UTF-8 emoji address bytes are accepted");

    std::string with_cr = standard_address + '\r';
    check(tari_miner::validate_wallet(with_cr) ==
              tari_miner::WalletValidationError::WhitespaceOrControl,
           "trailing carriage return is rejected");
    for (char invalid : std::string(" \t\n\v\f")) {
        std::string address = standard_address;
        address[10] = invalid;
        check(tari_miner::validate_wallet(address) ==
                  tari_miner::WalletValidationError::WhitespaceOrControl,
               "embedded whitespace is rejected");
    }
    for (unsigned char invalid : {0x01, 0x1f, 0x7f}) {
        std::string address = standard_address;
        address[10] = static_cast<char>(invalid);
        check(tari_miner::validate_wallet(address) ==
                  tari_miner::WalletValidationError::WhitespaceOrControl,
              "embedded control byte is rejected");
    }

    check(tari_miner::validate_wallet("") ==
              tari_miner::WalletValidationError::Empty,
          "an empty wallet is rejected");
    check(tari_miner::validate_wallet(
              std::string(tari_miner::TARI_HEX_MAX_LENGTH, 'a')) ==
              tari_miner::WalletValidationError::None,
          "the longest hex address length is accepted");

    std::string max_emoji_address;
    for (size_t i = 0; i < tari_miner::TARI_DUAL_INTERNAL_MAX_SIZE; ++i)
        max_emoji_address += "\xf0\x9f\x90\xa2";
    check(max_emoji_address.size() ==
              tari_miner::TARI_EMOJI_MAX_UTF8_LENGTH &&
              tari_miner::validate_wallet(max_emoji_address) ==
                  tari_miner::WalletValidationError::None,
          "the longest UTF-8 emoji address length is accepted");

    std::string grouped_emoji_address;
    for (size_t i = 0; i < tari_miner::TARI_DUAL_INTERNAL_MAX_SIZE; ++i) {
        if (i) grouped_emoji_address.push_back('|');
        grouped_emoji_address += "\xf0\x9f\x90\xa2";
    }
    check(grouped_emoji_address.size() ==
              tari_miner::TARI_GROUPED_EMOJI_MAX_UTF8_LENGTH &&
              tari_miner::validate_wallet(grouped_emoji_address) ==
                  tari_miner::WalletValidationError::None,
          "the longest pipe-grouped emoji address length is accepted");
    check(tari_miner::validate_wallet(std::string(444, 'z')) ==
              tari_miner::WalletValidationError::None,
          "a long generic pool login is accepted");
    check(tari_miner::validate_wallet(
              std::string(tari_miner::MAX_WALLET_LENGTH + 1, 'a')) ==
              tari_miner::WalletValidationError::TooLong,
          "an overlong wallet or login is rejected");
}

static void test_tari_address_charset() {
    std::puts("Tari address charset:");
    // A dual address is 89-443 Base58 characters; a single address is 45-48.
    // The filler is deliberately not a hex digit: a login made only of [0-9a-f]
    // is exempt from the charset rule, and a real address is not hex.
    const std::string dual = "f2" + std::string(89, 'z');
    const std::string single = "f2" + std::string(44, 'z');
    check(tari_miner::validate_wallet(dual) ==
              tari_miner::WalletValidationError::None,
          "a dual-length Base58 address is accepted");
    check(tari_miner::validate_wallet(single) ==
              tari_miner::WalletValidationError::None,
          "a single-length Base58 address is accepted");

    for (char typo : std::string("0OIl")) {
        std::string address = dual;
        address[40] = typo;
        check(tari_miner::validate_wallet(address) ==
                  tari_miner::WalletValidationError::TariAddressCharset,
              "an address-shaped login with a non-Base58 character is rejected");

        std::string short_address = single;
        short_address[20] = typo;
        check(tari_miner::validate_wallet(short_address) ==
                  tari_miner::WalletValidationError::TariAddressCharset,
              "a single-length address with a non-Base58 character is rejected");
    }

    std::string generic_single = "12" + std::string(44, 'z');
    generic_single[20] = '0';
    check(tari_miner::validate_wallet(generic_single) ==
              tari_miner::WalletValidationError::TariAddressCharset &&
              !tari_miner::wallet_validation_is_fatal(
                  tari_miner::validate_wallet(generic_single)),
          "an ambiguous address-length login warns but is not rejected");
    std::string generic_dual = "f2" + std::string(89, 'z');
    generic_dual[40] = 'O';
    check(tari_miner::validate_wallet(generic_dual) ==
              tari_miner::WalletValidationError::TariAddressCharset &&
              !tari_miner::wallet_validation_is_fatal(
                  tari_miner::validate_wallet(generic_dual)),
          "a long ambiguous login warns but is not rejected");
    std::string prefix_typo = "fO" + std::string(89, 'z');
    check(tari_miner::validate_wallet(prefix_typo) ==
              tari_miner::WalletValidationError::TariAddressCharset,
          "a Base58 typo in the Tari prefix is detected");

    // Lengths between and beyond the address ranges are logins, not addresses.
    for (size_t length : {size_t(44), size_t(60), size_t(88)}) {
        std::string login(length, '0');
        check(tari_miner::validate_wallet(login) ==
                  tari_miner::WalletValidationError::None,
              "a login that is not address-shaped skips the charset rule");
    }

    std::string with_symbol = dual;
    with_symbol[40] = '-';
    check(tari_miner::validate_wallet(with_symbol) ==
              tari_miner::WalletValidationError::None,
          "a punctuated login of address length is not treated as an address");
    check(tari_miner::validate_wallet(std::string(96, '0')) ==
              tari_miner::WalletValidationError::None,
          "an all-hex login of address length is not treated as an address");
    check(tari_miner::validate_wallet("custom-pool-login") ==
              tari_miner::WalletValidationError::None,
          "a short custom login is still accepted");
}

static void test_pool_response_classification() {
    std::puts("Pool response classification:");
    using tari_miner::PoolResponseKind;
    tari_miner::PoolResponseTracker tracker;
    check(tracker.classify(true, 1, true, false, false, false, true) ==
              PoolResponseKind::LoginError,
          "login error is classified separately");
    check(tracker.classify(true, 1, false, true, false, true, true) ==
              PoolResponseKind::LoginError,
          "login result false is classified as a fatal rejection");
    check(tracker.classify(true, 1, false, true, true, false, true) ==
              PoolResponseKind::Other,
           "login success is not counted as an accepted share");
    check(tracker.classify(true, 1, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "a late login-id error is not treated as a new login failure");

    uint64_t first = tracker.begin_submit();
    uint64_t second = tracker.begin_submit();
    check(first != second && tracker.pending_submits() == 2,
          "submit request IDs are unique and tracked");
    check(tracker.classify(true, second, true, false, false, false, false) ==
              PoolResponseKind::ShareRejected,
          "tracked submit error is a rejected share");
    check(tracker.classify(true, first, false, true, true, false, false) ==
              PoolResponseKind::ShareAccepted,
          "tracked submits can complete out of order");
    check(tracker.pending_submits() == 0,
          "terminal responses consume pending submit IDs");
    check(tracker.classify(true, first, false, true, true, false, false) ==
              PoolResponseKind::Other,
          "duplicate submit response is ignored");
    check(tracker.classify(true, 999, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "unmatched error is not a rejected share");

    uint64_t third = tracker.begin_submit();
    check(tracker.classify(true, third, false, true, false, true, false) ==
              PoolResponseKind::ShareRejected,
          "tracked result false is a rejected share");
    uint64_t cancelled = tracker.begin_submit();
    tracker.cancel_submit(cancelled);
    check(tracker.classify(true, cancelled, false, true, true, false, false) ==
              PoolResponseKind::Other,
           "failed send cancels its pending submit");
    uint64_t incomplete = tracker.begin_submit();
    check(tracker.classify(true, incomplete, false, false, false, false, false) ==
              PoolResponseKind::Other &&
              tracker.pending_submits() == 1 &&
              tracker.classify(true, incomplete, false, true, true, false, false) ==
              PoolResponseKind::ShareAccepted &&
              tracker.pending_submits() == 0,
          "a nonterminal response cannot consume a pending submit");
    uint64_t other_result = tracker.begin_submit();
    check(tracker.classify(
              true, other_result, false, true, false, false, false) ==
              PoolResponseKind::Other &&
              tracker.pending_submits() == 0,
          "an explicit non-boolean result terminates without counting a share");
    check(tracker.classify(false, 0, true, false, false, false, true) ==
              PoolResponseKind::LoginError,
          "an id-less error before login completes is fatal");
    check(tracker.classify(false, 0, true, false, false, false, false) ==
              PoolResponseKind::OtherError,
          "an unrelated pool error is not counted as a share reject");
}

static void test_pending_submit_bound() {
    std::puts("Pending submit bound:");
    tari_miner::PoolResponseTracker tracker;
    uint64_t first = tracker.begin_submit();
    for (size_t i = 1; i < tari_miner::MAX_PENDING_SUBMITS; ++i)
        tracker.begin_submit();
    check(tracker.pending_submits() == tari_miner::MAX_PENDING_SUBMITS,
          "the tracker fills to its bound");

    uint64_t newest = tracker.begin_submit();
    check(tracker.pending_submits() == tari_miner::MAX_PENDING_SUBMITS,
          "a silent pool cannot grow the pending set without limit");
    check(tracker.classify(true, first, false, true, true, false, false) ==
              tari_miner::PoolResponseKind::Other,
          "the oldest submit is the one forgotten at the bound");
    check(tracker.classify(true, newest, false, true, true, false, false) ==
              tari_miner::PoolResponseKind::ShareAccepted,
          "the newest submit is still tracked");
}

static void test_status_ok_acceptance() {
    std::puts("Status-object share acceptance:");
    using tari_miner::PoolResponseKind;
    tari_miner::PoolResponseTracker tracker;
    uint64_t submit = tracker.begin_submit();
    check(tracker.classify(true, submit, false, true, false, false, false, true) ==
              PoolResponseKind::ShareAccepted,
          "a submit answered with a status object counts as accepted");

    tari_miner::PoolResponseTracker login_tracker;
    check(login_tracker.classify(
              true, tari_miner::LOGIN_REQUEST_ID, false, true, false, false,
              true, true) == PoolResponseKind::Other,
          "the login status object is not counted as an accepted share");

    uint64_t rejected = tracker.begin_submit();
    check(tracker.classify(true, rejected, true, true, false, false, false, true) ==
              PoolResponseKind::ShareRejected,
          "an error outranks a status object on the same response");
}

static void test_pool_silence_policy() {
    std::puts("Pool silence policy:");
    check(tari_miner::POOL_SILENT_EXIT_CODE == 6,
          "an unresponsive pool uses exit code 6");
    tari_miner::PoolSilencePolicy policy;
    check(!policy.record_silence() && policy.consecutive_silences() == 1,
          "the first silent connection retries");
    check(policy.backoff_seconds() == tari_miner::FIRST_SILENT_BACKOFF_SECONDS,
          "the first retry uses the base backoff");
    check(!policy.record_silence() &&
              policy.backoff_seconds() ==
                  tari_miner::FIRST_SILENT_BACKOFF_SECONDS * 2,
          "the backoff doubles");

    for (unsigned i = 0; i < 6; ++i) policy.record_silence();
    check(policy.backoff_seconds() == tari_miner::MAX_SILENT_BACKOFF_SECONDS,
          "the backoff is capped");

    policy.record_job();
    check(policy.consecutive_silences() == 0 &&
              policy.backoff_seconds() ==
                  tari_miner::FIRST_SILENT_BACKOFF_SECONDS,
          "a received job resets the policy");

    tari_miner::PoolSilencePolicy fatal_policy;
    bool fatal = false;
    for (unsigned i = 0; i < tari_miner::MAX_SILENT_CYCLES; ++i)
        fatal = fatal_policy.record_silence();
    check(fatal, "a persistently silent pool eventually exits");

    using tari_miner::JobWaitOutcome;
    check(tari_miner::counts_as_pool_silence(JobWaitOutcome::Timeout),
          "a connected no-job timeout counts as pool silence");
    check(!tari_miner::counts_as_pool_silence(JobWaitOutcome::Disconnected) &&
              !tari_miner::counts_as_pool_silence(JobWaitOutcome::ProtocolError) &&
              !tari_miner::counts_as_pool_silence(JobWaitOutcome::LoginRejected),
          "disconnects and protocol/login errors are not pool silence");
    tari_miner::PoolSilencePolicy interrupted;
    interrupted.record_silence();
    interrupted.reset();
    check(interrupted.consecutive_silences() == 0,
          "non-silent activity breaks a silence streak");
}

static void test_protocol_error_policy() {
    std::puts("Pool protocol error policy:");
    check(tari_miner::POOL_PROTOCOL_EXIT_CODE == 7,
          "a persistently invalid pool uses exit code 7");
    tari_miner::ProtocolErrorPolicy policy;
    check(!policy.record_failure() && !policy.record_failure(),
          "the first two protocol errors retry");
    check(policy.record_failure() &&
              policy.consecutive_failures() ==
                  tari_miner::MAX_PROTOCOL_ERRORS,
          "the third consecutive protocol error exits");
    policy.record_valid_job(1);
    check(policy.consecutive_failures() == tari_miner::MAX_PROTOCOL_ERRORS,
          "an initial job on a retry does not reset protocol errors");
    policy.record_valid_job(2);
    check(policy.consecutive_failures() == 0,
          "a valid job update resets protocol errors");
    policy.record_failure();
    policy.record_valid_job(2);
    check(!policy.record_failure() && policy.consecutive_failures() == 1,
          "a valid update observed on the error path resets before counting");
    policy.reset();
    check(policy.consecutive_failures() == 0,
          "a clean connection or valid job update resets protocol errors");
}

static void test_login_failure_policy() {
    std::puts("Login failure policy:");
    check(tari_miner::LOGIN_FAILURE_EXIT_CODE == 4,
          "fatal login rejection uses exit code 4");
    tari_miner::LoginFailurePolicy policy;
    check(!policy.record_failure() && policy.consecutive_failures() == 1,
          "first explicit login failure retries");
    check(!policy.record_failure() && policy.consecutive_failures() == 2,
          "second explicit login failure retries");
    policy.record_success();
    check(policy.consecutive_failures() == 0,
          "successful job resets login failures");
    check(!policy.record_failure() && !policy.record_failure() &&
              policy.record_failure(),
          "third consecutive login failure exits");
}

static void test_solver_watchdog() {
    std::puts("Solver watchdog:");
    check(tari_miner::SOLVER_FAILURE_EXIT_CODE == 5,
          "fatal solver failure uses exit code 5");
    tari_miner::SolverWatchdog watchdog;
    check(watchdog.observe(1000, true), "healthy trim is accepted");
    check(watchdog.observe(0, true) && watchdog.consecutive_zero_yields() == 1,
          "first zero-yield trim is tolerated");
    check(watchdog.observe(1000, true) && watchdog.consecutive_zero_yields() == 0,
          "healthy trim resets the zero-yield count");
    check(watchdog.observe(0, true), "first consecutive zero yield is tolerated");
    check(watchdog.observe(0, true), "second consecutive zero yield is tolerated");
    check(!watchdog.observe(0, true) &&
              watchdog.failure() == tari_miner::SolverFailure::ZeroYield,
          "third consecutive zero yield trips the watchdog");
    check(!watchdog.observe(1000, true),
          "watchdog failure remains sticky");

    tari_miner::SolverWatchdog cuda_watchdog;
    check(!cuda_watchdog.observe(0, false) &&
              cuda_watchdog.failure() == tari_miner::SolverFailure::Cuda,
          "CUDA failure takes priority and trips immediately");
    check(cuda_watchdog.consecutive_zero_yields() == 0,
          "CUDA failure is not counted as a zero yield");

    tari_miner::SolverWatchdog first_context;
    tari_miner::SolverWatchdog second_context;
    check(first_context.observe(0, true) &&
              first_context.observe(0, true) &&
              second_context.observe(1000, true),
          "solver contexts track health independently");
    check(!first_context.observe(0, true) &&
              second_context.observe(1000, true) &&
              second_context.failure() == tari_miner::SolverFailure::None,
          "one failed context does not poison another");
}

static void test_log_rate_limiter() {
    std::puts("Pool log rate limit:");
    tari_miner::LogRateLimiter limiter;
    uint64_t suppressed = 99;
    unsigned logged = 0;
    for (unsigned i = 0; i < 25; ++i) {
        if (limiter.allow(1.0 + i, suppressed)) logged++;
        if (suppressed) break;
    }
    check(logged == tari_miner::POOL_LOG_LIMIT,
          "only the limit is logged within one window");
    check(suppressed == 0, "nothing is reported mid-window");
    check(limiter.allow(61.0, suppressed) && suppressed == 15,
          "a new window logs again and reports the suppressed count");
    check(limiter.allow(62.0, suppressed) && suppressed == 0,
          "the suppressed count is reported once");
    check(limiter.allow(10.0, suppressed) && suppressed == 0,
          "a clock going backwards starts a new window");
}

static bool near(double actual, double expected) {
    return actual > expected - 1e-9 && actual < expected + 1e-9;
}

static void test_reconnect_pause() {
    std::puts("Reconnect pause:");
    check(near(tari_miner::reconnect_pause_seconds(0.2), 14.8),
          "a connection closed right after login waits out the window");
    check(near(tari_miner::reconnect_pause_seconds(14.9), 0.1),
          "a connection that almost lasted the window barely waits");
    check(tari_miner::reconnect_pause_seconds(tari_miner::SHORT_CONNECTION_SEC) == 0.0,
          "a connection that lasted the window reconnects at once");
    check(tari_miner::reconnect_pause_seconds(3600.0) == 0.0,
          "a long connection reconnects at once");
    check(tari_miner::reconnect_pause_seconds(-1.0) == tari_miner::SHORT_CONNECTION_SEC,
          "a clock going backwards waits the full window");
    check(tari_miner::reconnect_pause_seconds(
              std::numeric_limits<double>::quiet_NaN()) ==
              tari_miner::SHORT_CONNECTION_SEC,
          "an unknown duration waits the full window");
}

static void test_superseded_job() {
    std::puts("Superseded job:");
    check(tari_miner::is_superseded(100, 101),
          "a job at a higher height supersedes the work");
    check(!tari_miner::is_superseded(100, 100),
          "a new job at the same height (template refresh) does not");
    check(!tari_miner::is_superseded(0, 101),
          "unknown work height is never superseded");
    check(!tari_miner::is_superseded(100, 0),
          "unknown latest height never supersedes");
    check(!tari_miner::is_superseded(0, 0),
          "both heights unknown is not superseded");
    check(!tari_miner::is_superseded(100, 99),
          "a lower height (reorg or rollback) does not supersede");
}

static void test_height_churn_guard() {
    std::puts("Height churn guard:");
    bool warn = false;
    {
        // One block every 30 s, for ten minutes.
        tari_miner::HeightChurnGuard guard;
        bool trusted = true;
        bool warned = false;
        for (int i = 0; i <= 20; ++i) {
            trusted = trusted && guard.observe(1000 + i, 30.0 * i, warn);
            warned = warned || warn;
        }
        check(trusted && !warned, "a normal block cadence is trusted");
    }
    {
        tari_miner::HeightChurnGuard guard;
        check(guard.observe(100, 0.0, warn), "the first height is trusted");
        check(guard.observe(100, 0.5, warn), "an unchanged height is trusted");
        bool trusted = true;
        for (int i = 1; i <= 3; ++i)
            trusted = trusted && guard.observe(100 + i, i, warn);
        check(trusted && !warn, "up to the limit of increases is trusted");
        check(!guard.observe(104, 4.0, warn) && warn,
              "one more increase in the window is not trusted, with a warning");
        check(!guard.observe(105, 5.0, warn) && !warn,
              "later increases stay untrusted, with no second warning");
        check(!guard.observe(105, 59.0, warn) && !warn,
              "the rest of the window stays untrusted");
        check(guard.observe(106, 60.0, warn) && !warn,
              "a new window is trusted again");

        bool warned = false;
        for (int i = 0; i < 10; ++i) {
            guard.observe(200 + i, 61.0 + i, warn);
            warned = warned || warn;
        }
        check(warned, "churn in the next window warns again");
        check(guard.observe(300, 30.0, warn),
              "time going backwards starts a new window");
    }
    {
        tari_miner::HeightChurnGuard guard;
        const uint64_t huge = std::numeric_limits<uint64_t>::max();
        check(guard.observe(100, 0.0, warn), "a normal height is trusted");
        check(guard.observe(huge, 1.0, warn), "a single huge height counts once");
        check(!tari_miner::is_superseded(huge, 101),
              "work for the huge height is not superseded by a normal one");
        check(guard.observe(101, 2.0, warn) && guard.observe(102, 30.0, warn),
              "heights after the huge one are still trusted");
        check(tari_miner::is_superseded(101, 102),
              "the next real block still supersedes");
    }
}

int main() {
    test_wallet_validation();
    test_tari_address_charset();
    test_pool_response_classification();
    test_pending_submit_bound();
    test_status_ok_acceptance();
    test_pool_silence_policy();
    test_protocol_error_policy();
    test_login_failure_policy();
    test_solver_watchdog();
    test_log_rate_limiter();
    test_reconnect_pause();
    test_superseded_job();
    test_height_churn_guard();
    std::printf("\n%s (%d failure%s)\n",
                failures == 0 ? "ALL PASSED" : "FAILED",
                failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
