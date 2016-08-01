
#include <memory.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include "settings.h"
#include <assert.h>

extern "C" {
#include "processor_cuda.h"
}

#include <stdio.h>
#include "math.h"

static void HandleError( cudaError_t err,
                         const char *file,
                         int line ) {
    if (err != cudaSuccess) {
        printf( "%s in %s at line %d\n", cudaGetErrorString( err ),
                file, line );
        exit( EXIT_FAILURE );
    }
}
#define CHK( err ) (HandleError( err, __FILE__, __LINE__ ))


uint8_t* alloc_sample_buffer() {
  uint8_t *p;
  /* size of uint8_t is one, explicityly */
  CHK(cudaHostAlloc(&p, BUFFER_SIZE, cudaHostAllocDefault));
 return p;
}

float* alloc_power() {
  float *p;
  /* size of uint8_t is one, explicityly */
  CHK(cudaHostAlloc(&p, NUM_NUBINS*sizeof(float), cudaHostAllocDefault));
  return p;
}


void print_timing (cudaEvent_t* start, cudaEvent_t* stop, const char* what) {
  float gpu_time;
  CHK(cudaEventElapsedTime(&gpu_time, *start, *stop));
  printf ("Timing %s : %fms \n",what, gpu_time);
}


#define FLOATIZE_X 8
/**
 * CUDA Kernel byte->float
 *
 */
__global__ void floatize(uint8_t* sample,cufftReal* fsample)  {
    int i = FLOATIZE_X*(blockDim.x * blockIdx.x + threadIdx.x);
    for (int j=0; j<FLOATIZE_X; j++) fsample[i+j]=float(sample[i+j]-128);
}

/**
 * CUDA reduction sum
 * we will take bsize complex numbers starting at ffts[istart+bsize*blocknumber]
 * and their copies in NCHUNS, and add the squares
 **/


__global__ void ps_reduce(cufftComplex *ffts, float* output_ps, size_t istart) {
  int tid=threadIdx.x;
  int bl=blockIdx.x;
  int nth=blockDim.x;
  int bsize=NUAVG;
  extern __shared__ float work[];
  assert (tid<bsize);
  //global pos
  size_t pos=istart+bl*bsize+tid;
  //chunk pos
  size_t cpos=tid;
  work[tid]=0;
  size_t chunk=0;
  while (chunk<NUM_FFT) {
    work[tid]+=ffts[pos].x*ffts[pos].x+ffts[pos].y*ffts[pos].y;
    if (cpos+nth<bsize) {
      cpos+=nth;
      pos+=nth;
    } else {
      chunk++;
      pos=istart+bl*bsize+tid+chunk*FFT_SIZE;
      cpos=tid;
    }
  }

  // now do the three reduce.
  int csum=nth/2;
  while (csum>0) {
    __syncthreads();
    if (tid<csum) {
      work[tid]+=work[tid+csum];
    }
    csum/=2;
  }
  if (tid==0) output_ps[bl]=work[0];
}
  


void cuda_test(uint8_t *buf, float* freq, float* power) {

  // cuda buffer and float buffer
  uint8_t *cbuf;
  CHK(cudaMalloc(&cbuf,BUFFER_SIZE));
  cufftReal *cfbuf;
  CHK(cudaMalloc(&cfbuf,BUFFER_SIZE*sizeof(cufftReal)));
  cufftComplex *ffts;
  CHK(cudaMalloc(&ffts,TRANSFORM_SIZE*NUM_FFT*sizeof(cufftComplex)));
  int istart=int(NUMIN*1e6/DELTA_NU)-NUAVG/2;
  for (size_t i=0;i<NUM_NUBINS;i++) freq[i]=(istart+i*NUAVG)/DELTA_NU/1e6;

    
  cufftHandle plan;
  //int oembed=TRANSFORM_SIZE*NUM_FFT+1;
  int fftsize=FFT_SIZE;
  int status=cufftPlanMany(&plan, 1, &fftsize, NULL, 0, 0, 
        NULL, TRANSFORM_SIZE,1, CUFFT_R2C, NUM_FFT);
  if (status!=CUFFT_SUCCESS) {
       printf ("Plan failed:");
       if (status==CUFFT_ALLOC_FAILED) printf("CUFFT_ALLOC_FAILED");
       if (status==CUFFT_INVALID_VALUE) printf ("CUFFT_INVALID_VALUE");
       if (status==CUFFT_INTERNAL_ERROR) printf ("CUFFT_INTERNAL_ERROR");
       if (status==CUFFT_SETUP_FAILED) printf ("CUFFT_SETUP_FAILED");
       if (status==CUFFT_INVALID_SIZE) printf ("CUFFT_INVALID_SIZE");
       printf("\n");
       exit(1);
  }

  cudaEvent_t tstart, tcpy,tfloatize,tfft,treduce;
  CHK(cudaEventCreate(&tstart));
  CHK(cudaEventCreate(&tcpy));
  CHK(cudaEventCreate(&tfloatize));
  CHK(cudaEventCreate(&tfft));
  CHK(cudaEventCreate(&treduce));

  cudaEventRecord(tstart, 0);
  // copy to device
  CHK(cudaMemcpy(cbuf,buf, BUFFER_SIZE, cudaMemcpyHostToDevice));

  cudaEventRecord(tcpy, 0);
  
  // floatize
  int threadsPerBlock = 1024;
  int blocksPerGrid = BUFFER_SIZE / threadsPerBlock/FLOATIZE_X;
  floatize<<<blocksPerGrid, threadsPerBlock>>>(cbuf,cfbuf);
  cudaEventRecord(tfloatize, 0);
  CHK(cudaGetLastError());
  
  status=cufftExecR2C(plan, cfbuf, ffts);
  cudaEventRecord(tfft, 0);
  if (status!=CUFFT_SUCCESS) {
     printf("CUFFT FAILED\n");
     exit(1);
  }    

  // now launch the final kernel
  ps_reduce<<<NUM_NUBINS,threadsPerBlock,threadsPerBlock>>>(ffts,power, istart);
  cudaEventRecord(treduce, 0);

  cudaThreadSynchronize();
  print_timing(&tstart,&tcpy,"MEM CPY");
  print_timing(&tcpy,&tfloatize,"FLOATIZE");
  print_timing(&tfloatize,&tfft,"FFT");
  print_timing(&tfft,&treduce,"REDUCE");
}


void ztest() {
  uint8_t *cbuf;
  CHK(cudaMalloc(&cbuf,BUFFER_SIZE));
  // floatize
  int threadsPerBlock = 1024;
  int blocksPerGrid = 32768;
  int Nth=
  printf ("%i %i",threadsPerBlock, blocksPerGrid);
  //  floatize<<<blocksPerGrid, threadsPerBlock>>>(cbuf);
  CHK(cudaGetLastError());

}
