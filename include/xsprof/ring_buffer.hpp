// Bounded SPSC ring buffer for the lock-free collector -> pipeline handoff.
// When full, push() fails so the caller can record a sample-loss Marker
// (the framework never silently drops without signalling).
#pragma once

#include <atomic>
#include <cstddef>
#include <vector>

namespace xsprof {

template <typename T>
class RingBuffer {
public:
    explicit RingBuffer(std::size_t capacity)
        : cap_(capacity + 1), buf_(capacity + 1) {}

    bool push(const T& v) {
        const std::size_t head = head_.load(std::memory_order_relaxed);
        const std::size_t next = (head + 1) % cap_;
        if (next == tail_.load(std::memory_order_acquire)) return false; // full
        buf_[head] = v;
        head_.store(next, std::memory_order_release);
        return true;
    }

    bool pop(T& out) {
        const std::size_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) return false; // empty
        out = buf_[tail];
        tail_.store((tail + 1) % cap_, std::memory_order_release);
        return true;
    }

    bool empty() const {
        return head_.load(std::memory_order_acquire) == tail_.load(std::memory_order_acquire);
    }

    std::size_t capacity() const { return cap_ - 1; }

private:
    std::size_t cap_;
    std::vector<T> buf_;
    alignas(64) std::atomic<std::size_t> head_{0};
    alignas(64) std::atomic<std::size_t> tail_{0};
};

} // namespace xsprof
