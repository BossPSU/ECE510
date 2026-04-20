#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>

#define N 1024

__global__ void gemm_naive(const float *A, const float *B, float *C, int n) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < n && col < n) {
        float sum = 0.0f;
        for (int k = 0; k < n; k++) {
            sum += A[row * n + k] * B[k * n + col];
        }
        C[row * n + col] = sum;
    }
}

int main() {
    size_t bytes = N * N * sizeof(float);

    float *h_A = (float *)malloc(bytes);
    float *h_B = (float *)malloc(bytes);
    float *h_C = (float *)malloc(bytes);

    srand(42);
    for (int i = 0; i < N * N; i++) {
        h_A[i] = (float)rand() / RAND_MAX;
        h_B[i] = (float)rand() / RAND_MAX;
    }

    float *d_A, *d_B, *d_C;
    cudaMalloc(&d_A, bytes);
    cudaMalloc(&d_B, bytes);
    cudaMalloc(&d_C, bytes);

    cudaMemcpy(d_A, h_A, bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, h_B, bytes, cudaMemcpyHostToDevice);

    dim3 threads(16, 16);
    dim3 blocks((N + threads.x - 1) / threads.x, (N + threads.y - 1) / threads.y);

    // Warmup
    gemm_naive<<<blocks, threads>>>(d_A, d_B, d_C, N);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        printf("Kernel launch error: %s\n", cudaGetErrorString(err));
        return 1;
    }
    cudaDeviceSynchronize();

    // Timed runs
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    int num_runs = 10;
    float total_ms = 0.0f;

    for (int i = 0; i < num_runs; i++) {
        cudaEventRecord(start);
        gemm_naive<<<blocks, threads>>>(d_A, d_B, d_C, N);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float ms = 0.0f;
        cudaEventElapsedTime(&ms, start, stop);
        total_ms += ms;
    }

    float avg_ms = total_ms / num_runs;
    double flops = 2.0 * N * N * N;
    double gflops = (flops / (avg_ms / 1000.0)) / 1e9;

    printf("GEMM Naive (%dx%d)\n", N, N);
    printf("Avg time:  %.3f ms\n", avg_ms);
    printf("FLOPs:     %.0f\n", flops);
    printf("Throughput: %.2f GFLOP/s\n", gflops);

    // Verify a single element
    cudaMemcpy(h_C, d_C, bytes, cudaMemcpyDeviceToHost);
    float check = 0.0f;
    for (int k = 0; k < N; k++) check += h_A[k] * h_B[k * N];
    printf("Verify C[0][0]: GPU=%.4f CPU=%.4f\n", h_C[0], check);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    free(h_A);
    free(h_B);
    free(h_C);

    return 0;
}
