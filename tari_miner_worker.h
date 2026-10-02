#pragma once

#include <condition_variable>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <type_traits>
#include <utility>

namespace tari_miner {

// One long-lived host thread that runs submitted jobs one at a time.
//
// Pipeline mode used to start a new OS thread per graph with std::async. A
// WorkerThread is created once per solver context instead, so its CUDA
// per-thread state (current device, per-thread default stream, last error)
// stays the same from one graph to the next.
//
// The queue holds one job that has not started yet. A job may be submitted
// while the previous one is still running, but submitting while another job
// is still waiting to start is a logic error: submit() then returns an
// invalid future (valid() == false) and the job is not run.
//
// stop() and the destructor run every job already accepted, then join, so a
// future returned by submit() is always eventually satisfied.
class WorkerThread {
public:
    WorkerThread() : WorkerThread(std::function<void()>()) {}

    // on_start, if set, runs once on the worker thread before any job.
    explicit WorkerThread(std::function<void()> on_start)
        : thread_([this, on_start]() { run(on_start); }) {}

    WorkerThread(const WorkerThread &) = delete;
    WorkerThread &operator=(const WorkerThread &) = delete;

    ~WorkerThread() { stop(); }

    template <class F>
    std::future<typename std::invoke_result<F>::type> submit(F &&f) {
        using R = typename std::invoke_result<F>::type;
        // packaged_task is move-only and std::function needs a copyable
        // target, so the task is shared with the queued wrapper.
        auto task = std::make_shared<std::packaged_task<R()>>(std::forward<F>(f));
        // Take the future before the worker can see the job.
        std::future<R> result = task->get_future();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_ || job_)
                return std::future<R>();
            job_ = [task]() { (*task)(); };
        }
        cv_.notify_one();
        return result;
    }

    // Runs any job already accepted, then joins. Safe to call more than once.
    // Must not be called from a job running on this worker.
    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_one();
        if (thread_.joinable())
            thread_.join();
    }

private:
    void run(const std::function<void()> &on_start) {
        if (on_start)
            on_start();
        while (true) {
            std::function<void()> job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || job_; });
                if (!job_)
                    return;
                job = std::move(job_);
                job_ = nullptr;
            }
            // packaged_task stores any exception in the future.
            job();
        }
    }

    std::mutex mutex_;
    std::condition_variable cv_;
    std::function<void()> job_;
    bool stopping_ = false;
    // Declared last so the members above exist before the thread starts.
    std::thread thread_;
};

} // namespace tari_miner
