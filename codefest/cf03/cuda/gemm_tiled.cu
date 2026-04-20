#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>

#define N 1024
#define TILE 8

__global__ void gemm_tiled(const float *A, const float *B, float *C, int n) {
    __shared__ float sA[TILE][TILE];
    __shared__ float sB[TILE][TILE];

    int row = blockIdx.y * TILE + threadIdx.y;
    int col = blockIdx.x * TILE + threadIdx.x;

    float sum = 0.0f;

    for (int t = 0; t < n / TILE; t++) {
        sA[threadIdx.y][threadIdx.x] = A[row * n + t * TILE + threadIdx.x];
        sB[threadIdx.y][threadIdx.x] = B[(t * TILE + threadIdx.y) * n + col];
        __syncthreads();

        for (int k = 0; k < TILE; k++) {
            sum += sA[threadIdx.y][k] * sB[k][threadIdx.x];
        }
        __syncthreads();
    }

    C[row * n + col] = sum;
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

    dim3 threads(TILE, TILE);
    dim3 blocks(N / TILE, N / TILE);

    // Warmup
    gemm_tiled<<<blocks, threads>>>(d_A, d_B, d_C, N);
    cudaDeviceSynchronize();

    // Timed runs
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    int num_runs = 10;
    float total_ms = 0.0f;

    for (int i = 0; i < num_runs; i++) {
        cudaEventRecord(start);
        gemm_tiled<<<blocks, threads>>>(d_A, d_B, d_C, N);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float ms = 0.0f;
        cudaEventElapsedTime(&ms, start, stop);
        total_ms += ms;
    }

    float avg_ms = total_ms / num_runs;
    double flops = 2.0 * N * N * N;
    double gflops = (flops / (avg_ms / 1000.0)) / 1e9;

    printf("GEMM Tiled (%dx%d, TILE=%d)\n", N, N, TILE);
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
