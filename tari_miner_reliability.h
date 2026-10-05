// Small, GPU-independent miner reliability policies.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <set>
#include <string>

namespace tari_miner {

enum class WalletValidationError {
    None,
    Empty,
    WhitespaceOrControl,
    TooLong,
    TariAddressCharset,
};

// Tari address sizes from base_layer/common_types/src/tari_address/mod.rs.
// Base58 single addresses encode to 45-48 characters and dual addresses to
// 89-443. A dual address can contain 67-323 bytes once its optional 256-byte
// payment ID is included; hex needs two characters per byte and each emoji is
// at most four UTF-8 bytes.
constexpr size_t TARI_SINGLE_ADDRESS_MIN_LENGTH = 45;
constexpr size_t TARI_SINGLE_ADDRESS_MAX_LENGTH = 48;
constexpr size_t TARI_DUAL_ADDRESS_MIN_LENGTH = 89;
constexpr size_t TARI_DUAL_ADDRESS_MAX_LENGTH = 443;
constexpr size_t TARI_DUAL_INTERNAL_MAX_SIZE = 67 + 256;
constexpr size_t TARI_HEX_MAX_LENGTH = TARI_DUAL_INTERNAL_MAX_SIZE * 2;
constexpr size_t TARI_EMOJI_MAX_UTF8_LENGTH =
    TARI_DUAL_INTERNAL_MAX_SIZE * 4;
constexpr size_t TARI_GROUPED_EMOJI_MAX_UTF8_LENGTH =
    TARI_EMOJI_MAX_UTF8_LENGTH + TARI_DUAL_INTERNAL_MAX_SIZE - 1;
constexpr size_t MAX_WALLET_LENGTH = TARI_GROUPED_EMOJI_MAX_UTF8_LENGTH;

// Bitcoin base58: the digits and letters, minus 0 O I l. Those four are exactly
// the characters a mistyped or OCR-read address tends to gain.
inline bool is_base58_char(unsigned char c) {
    if (c >= '1' && c <= '9') return true;
    if (c >= 'a' && c <= 'z') return c != 'l';
    if (c >= 'A' && c <= 'Z') return c != 'I' && c != 'O';
    return false;
}

inline bool has_tari_address_length(size_t length) {
    return (length >= TARI_SINGLE_ADDRESS_MIN_LENGTH &&
            length <= TARI_SINGLE_ADDRESS_MAX_LENGTH) ||
           (length >= TARI_DUAL_ADDRESS_MIN_LENGTH &&
            length <= TARI_DUAL_ADDRESS_MAX_LENGTH);
}

inline bool is_ascii_alnum(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z');
}

inline bool is_hex_string(const std::string &text) {
    for (unsigned char c : text) {
        bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                   (c >= 'A' && c <= 'F');
        if (!hex) return false;
    }
    return true;
}

// This field is not always a Tari address: pools exist that expect a username,
// which is why --login-separator exists. So the charset rule is applied only to
// strings already shaped like an address - the length of one, and nothing but
// ASCII letters and digits. Anything else is passed through, and it is the pool
// that decides whether the login is good.
inline WalletValidationError validate_wallet(const std::string &wallet) {
    if (wallet.empty()) return WalletValidationError::Empty;

    for (unsigned char c : wallet) {
        if (c <= 0x20 || c == 0x7f)
            return WalletValidationError::WhitespaceOrControl;
    }
    if (wallet.size() > MAX_WALLET_LENGTH)
        return WalletValidationError::TooLong;

    if (!has_tari_address_length(wallet.size()))
        return WalletValidationError::None;
    for (unsigned char c : wallet) {
        if (!is_ascii_alnum(c)) return WalletValidationError::None;
    }
    // An all-hex login of the same length is a login, not a mistyped address:
    // the only non-base58 character it can hold is '0'.
    if (is_hex_string(wallet)) return WalletValidationError::None;

    for (unsigned char c : wallet) {
        if (!is_base58_char(c))
            return WalletValidationError::TariAddressCharset;
    }
    return WalletValidationError::None;
}

inline bool wallet_validation_is_fatal(WalletValidationError error) {
    return error != WalletValidationError::None &&
           error != WalletValidationError::TariAddressCharset;
}

enum class PoolResponseKind {
    Other,
    LoginError,
    ShareAccepted,
    ShareRejected,
    OtherError,
};

constexpr uint64_t LOGIN_REQUEST_ID = 1;
constexpr uint64_t FIRST_SUBMIT_REQUEST_ID = 4;

// A pool that never answers a submit would otherwise grow the pending set for
// as long as the miner runs. Beyond this many outstanding submits the oldest
// is forgotten; it can then only be classified as an unmatched response.
constexpr size_t MAX_PENDING_SUBMITS = 256;

class PoolResponseTracker {
public:
    uint64_t begin_submit() {
        uint64_t id = next_submit_id_++;
        pending_submits_.insert(id);
        while (pending_submits_.size() > MAX_PENDING_SUBMITS)
            pending_submits_.erase(pending_submits_.begin());
        return id;
    }

    void cancel_submit(uint64_t id) {
        pending_submits_.erase(id);
    }

    PoolResponseKind classify(
        bool has_id,
        uint64_t id,
        bool has_error,
        bool has_result,
        bool result_true,
        bool result_false,
        bool login_pending,
        bool result_status_ok = false
    ) {
        if ((has_error || result_false) && login_pending &&
            ((!has_id) || id == LOGIN_REQUEST_ID))
            return PoolResponseKind::LoginError;

        auto pending = has_id ? pending_submits_.find(id) : pending_submits_.end();
        if (pending != pending_submits_.end()) {
            if (!has_error && !has_result)
                return PoolResponseKind::Other;
            pending_submits_.erase(pending);
            if (has_error || result_false) {
                return PoolResponseKind::ShareRejected;
            }
            if (result_true || result_status_ok) {
                return PoolResponseKind::ShareAccepted;
            }
            return PoolResponseKind::Other;
        }

        if (has_error) return PoolResponseKind::OtherError;
        return PoolResponseKind::Other;
    }

    size_t pending_submits() const {
        return pending_submits_.size();
    }

private:
    uint64_t next_submit_id_ = FIRST_SUBMIT_REQUEST_ID;
    // Ordered so the oldest outstanding submit is the one dropped at the cap.
    std::set<uint64_t> pending_submits_;
};

constexpr unsigned MAX_LOGIN_FAILURES = 3;
constexpr int LOGIN_FAILURE_EXIT_CODE = 4;
constexpr unsigned LOGIN_RETRY_SECONDS = 5;

class LoginFailurePolicy {
public:
    bool record_failure() {
        consecutive_failures_++;
        return consecutive_failures_ >= MAX_LOGIN_FAILURES;
    }

    void record_success() {
        consecutive_failures_ = 0;
    }

    unsigned consecutive_failures() const {
        return consecutive_failures_;
    }

private:
    unsigned consecutive_failures_ = 0;
};

// A pool that accepts the connection but never sends a job produces no error to
// count, so the login policy above never fires. Bound that case separately:
// back off between attempts, then exit so a supervisor can react.
constexpr unsigned MAX_SILENT_CYCLES = 10;
constexpr int POOL_SILENT_EXIT_CODE = 6;
constexpr unsigned FIRST_SILENT_BACKOFF_SECONDS = 5;
constexpr unsigned MAX_SILENT_BACKOFF_SECONDS = 60;

class PoolSilencePolicy {
public:
    // Returns true when the miner should stop retrying.
    bool record_silence() {
        consecutive_silences_++;
        return consecutive_silences_ >= MAX_SILENT_CYCLES;
    }

    void record_job() {
        reset();
    }

    void reset() {
        consecutive_silences_ = 0;
    }

    unsigned consecutive_silences() const {
        return consecutive_silences_;
    }

    // Doubling backoff, capped, so a pool outage is not hammered.
    unsigned backoff_seconds() const {
        unsigned seconds = FIRST_SILENT_BACKOFF_SECONDS;
        for (unsigned i = 1; i < consecutive_silences_; ++i) {
            if (seconds >= MAX_SILENT_BACKOFF_SECONDS)
                return MAX_SILENT_BACKOFF_SECONDS;
            seconds *= 2;
        }
        return seconds < MAX_SILENT_BACKOFF_SECONDS
            ? seconds
            : MAX_SILENT_BACKOFF_SECONDS;
    }

private:
    unsigned consecutive_silences_ = 0;
};

enum class JobWaitOutcome {
    Job,
    LoginRejected,
    ProtocolError,
    Disconnected,
    Timeout,
};

inline bool counts_as_pool_silence(JobWaitOutcome outcome) {
    return outcome == JobWaitOutcome::Timeout;
}

constexpr unsigned MAX_PROTOCOL_ERRORS = 3;
constexpr int POOL_PROTOCOL_EXIT_CODE = 7;

class ProtocolErrorPolicy {
public:
    bool record_failure() {
        consecutive_failures_++;
        return consecutive_failures_ >= MAX_PROTOCOL_ERRORS;
    }

    void record_valid_job(uint64_t session_job_sequence) {
        // The first job is expected before every retry, so it does not prove
        // recovery from a pool that always fails on its first update.
        if (session_job_sequence > 1)
            reset();
    }

    void reset() {
        consecutive_failures_ = 0;
    }

    unsigned consecutive_failures() const {
        return consecutive_failures_;
    }

private:
    unsigned consecutive_failures_ = 0;
};

constexpr unsigned MAX_CONSECUTIVE_ZERO_YIELDS = 3;
constexpr int SOLVER_FAILURE_EXIT_CODE = 5;

enum class SolverFailure {
    None,
    Cuda,
    ZeroYield,
};

class SolverWatchdog {
public:
    bool observe(uint32_t surviving_edges, bool cuda_ok) {
        if (failure_ != SolverFailure::None) return false;
        if (!cuda_ok) {
            failure_ = SolverFailure::Cuda;
            return false;
        }
        if (surviving_edges == 0) {
            consecutive_zero_yields_++;
            if (consecutive_zero_yields_ >= MAX_CONSECUTIVE_ZERO_YIELDS) {
                failure_ = SolverFailure::ZeroYield;
                return false;
            }
        } else {
            consecutive_zero_yields_ = 0;
        }
        return true;
    }

    unsigned consecutive_zero_yields() const {
        return consecutive_zero_yields_;
    }

    SolverFailure failure() const {
        return failure_;
    }

private:
    unsigned consecutive_zero_yields_ = 0;
    SolverFailure failure_ = SolverFailure::None;
};

// A pool can send errors, share rejections and jobs without limit. Log at most
// this many of each kind per window, plus one "N more not logged" line when
// the next message arrives in a later window (a count still pending when the
// pool goes quiet is not printed). The limits live for the whole process, so
// reconnecting does not reset them. Each such line is under about 400 bytes
// (pool text is capped at 256), so each kind adds at most about 4.5 KB per
// minute, and the three together under 30 KB in any 15 s, across reconnects.
// That keeps the latest speed report inside the last 1 MiB of the log that
// hiveos/h-stats.sh reads. It bounds the rate, not the total: the logs still
// grow over days and are not rotated.
constexpr unsigned POOL_LOG_LIMIT = 10;
constexpr double POOL_LOG_WINDOW_SEC = 60.0;

// Lets at most POOL_LOG_LIMIT messages through per window and counts the
// rest. Holds no clock: the caller passes the time in.
class LogRateLimiter {
public:
    // Returns true when this message should be logged. When it starts a new
    // window, suppressed is set to the number of messages dropped in the
    // previous one, so the caller can report them; otherwise it is set to 0.
    bool allow(double t_sec, uint64_t &suppressed) {
        suppressed = 0;
        if (!started_ || t_sec - window_start_ >= POOL_LOG_WINDOW_SEC ||
            t_sec < window_start_) {
            suppressed = suppressed_;
            started_ = true;
            window_start_ = t_sec;
            logged_ = 0;
            suppressed_ = 0;
        }
        if (logged_ < POOL_LOG_LIMIT) {
            logged_++;
            return true;
        }
        suppressed_++;
        return false;
    }

private:
    bool started_ = false;
    double window_start_ = 0.0;
    unsigned logged_ = 0;
    uint64_t suppressed_ = 0;
};

struct PoolLogLimits {
    LogRateLimiter error;
    LogRateLimiter rejected;
    LogRateLimiter job;
};

// A connection that ends cleanly sooner than this after it started is followed
// by a pause for the rest of this time, so a pool that closes the connection
// right after login cannot make the miner reconnect (and log a new connection)
// more than once per SHORT_CONNECTION_SEC, and a connection that lasted almost
// that long costs almost no wait. A normal long-lived connection that drops
// still reconnects at once.
constexpr double SHORT_CONNECTION_SEC = 15.0;

// Seconds to wait before reconnecting after a connection that lasted
// connection_sec. A negative or unknown duration waits the full time.
inline double reconnect_pause_seconds(double connection_sec) {
    if (!(connection_sec >= 0.0))
        return SHORT_CONNECTION_SEC;
    if (connection_sec >= SHORT_CONNECTION_SEC)
        return 0.0;
    return SHORT_CONNECTION_SEC - connection_sec;
}

// True when a graph trimmed for a job at work_height is no longer worth a
// cycle search or a share, because the pool has moved on to a higher block.
// Height 0 means the pool did not send one, so nothing is skipped. A new job
// at the same height (a template refresh) still takes shares, and a lower
// height (a reorg or rollback) is not treated as newer.
inline bool is_superseded(uint64_t work_height, uint64_t latest_height) {
    if (work_height == 0 || latest_height == 0)
        return false;
    return latest_height > work_height;
}

} // namespace tari_miner
