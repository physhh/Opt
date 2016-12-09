#pragma once
#include <cuda_runtime.h>
#include "cudaUtil.h"
#include <assert.h>
#include <vector>
template <class T>
class CudaArray {
public:
    void update(const T* newData, size_t count) {
        destructiveResize(count);
        cutilSafeCall(cudaMemcpy(m_data, newData, sizeof(T)*m_size, cudaMemcpyHostToDevice));
    }

    void update(const std::vector<T>& newData) {
        update(newData.data(), newData.size());
    }

    void readBack(std::vector<T>& cpuBuffer) {
        cpuBuffer.resize(m_size);
        cutilSafeCall(cudaMemcpy(cpuBuffer.data(), m_data, sizeof(T)*m_size, cudaMemcpyDeviceToHost));
    }

    void destructiveResize(size_t count) {
        if (count > m_allocated) {
            if (m_data) {
                cutilSafeCall(cudaFree(m_data));
            }
            m_allocated = count;
            cutilSafeCall(cudaMalloc(&m_data, sizeof(T)*count));
        }
        m_size = count;
    }

    void alloc(size_t count) {
        assert(m_size == 0);
        destructiveResize(count);
    }

    size_t size() const {
        return m_size;
    }

    T* data() const {
        return m_data;
    }

    CudaArray() {}

    ~CudaArray() {
        if (m_data) {
            cutilSafeCall(cudaFree(m_data));
        }
    }

protected:
    size_t m_allocated = 0;
    size_t m_size = 0;
    T* m_data = nullptr;
};