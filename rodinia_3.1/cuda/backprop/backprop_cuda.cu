

// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <cuda.h>
#include <sys/time.h>

// includes, kernels
#include "backprop_cuda_kernel.cu"
#include "backprop.h"

//#define CUDA_UVM

////////////////////////////////////////////////////////////////////////////////

extern "C"
void bpnn_layerforward(float *l1, float *l2, float **conn, int n1, int n2);

extern "C"
void bpnn_output_error(float *delta, float *target, float *output, int nj, float *err);

extern "C"
void bpnn_hidden_error(float *delta_h, int nh, float *delta_o, int no, float **who, float *hidden, float *err);

extern "C" 
void bpnn_adjust_weights(float *delta, int ndelta, float *ly, int nly, float **w, float **oldw);


extern "C"
int setup(int argc, char** argv);

extern "C"
float **alloc_2d_dbl(int m, int n);

extern "C"
float squash(float x);

double gettime() {
  struct timeval t;
  gettimeofday(&t,NULL);
  return t.tv_sec+t.tv_usec*1e-6;
}

unsigned int num_threads = 0;
unsigned int num_blocks = 0;

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main( int argc, char** argv) 
{
	setup(argc, argv);
}


extern "C"
void bpnn_train_cuda(BPNN *net, float *eo, float *eh)
{
  unsigned long long in, hid, out;
  float out_err, hid_err;
  
  in = net->input_n;
  hid = net->hidden_n;
  out = net->output_n;   
   
#ifdef GPU  
  int m = 0;
#ifndef CUDA_UVM
  float *input_cuda;
  float *input_hidden_cuda;
  float *hidden_partial_sum;
  float *hidden_delta_cuda;
  float *input_prev_weights_cuda;
#endif
  float *output_hidden_cuda;
  float *partial_sum;
  float sum;
  float *input_weights_one_dim;
  float *input_weights_prev_one_dim;
  num_blocks = in / 16;  
  //dim3  grid( 1 , num_blocks);
  dim3  grid(num_blocks, 1);
  dim3  threads(16 , 16);
  
#ifndef CUDA_UVM
  input_weights_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
  partial_sum = (float *) malloc(num_blocks * WIDTH * sizeof(float));
  input_weights_prev_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
#else
  cudaMallocManaged((void**) &input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float));
  cudaMallocManaged((void**) &partial_sum, num_blocks * WIDTH * sizeof(float));
  cudaMallocManaged((void**) &input_weights_prev_one_dim, (in + 1)* (hid + 1) * sizeof(float));
#endif
 
  // this preprocessing stage is added to correct the bugs of wrong memcopy using two-dimensional net->inputweights
  for (int k = 0; k <= in; k++) {	
   for (int j = 0; j <= hid; j++) {
	  input_weights_one_dim[m] = net->input_weights[k][j];
	  input_weights_prev_one_dim[m] = net-> input_prev_weights[k][j];
	  m++;
    }
  }
  
  double cur_time = gettime();
#ifndef CUDA_UVM
  cudaMalloc((void**) &input_cuda, (in + 1) * sizeof(float));
  //cudaMalloc((void**) &output_hidden_cuda, (hid + 1) * sizeof(float));
  cudaMalloc((void**) &input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float));
  cudaMalloc((void**) &hidden_partial_sum, num_blocks * WIDTH * sizeof(float));
#endif
  unsigned long long total_size = (in + 1) * (hid + 1) * sizeof(float) + (in + 1) * sizeof(float) + num_blocks * WIDTH * sizeof(float);
  
  
#endif

#ifdef CPU

  printf("Performing CPU computation\n");
  bpnn_layerforward(net->input_units, net->hidden_units,net->input_weights, in, hid);

#endif

#ifdef GPU
 
  printf("Performing GPU computation\n");
  
  //printf("in= %d, hid = %d, numblocks = %d\n", in, hid, num_blocks);
  
#ifndef CUDA_UVM
  cudaMemcpy(input_cuda, net->input_units, (in + 1) * sizeof(float), cudaMemcpyHostToDevice);
  //cudaMalloc((void**) &output_hidden_cuda, (hid + 1) * sizeof(float));
  cudaMemcpy(input_hidden_cuda, input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
#endif

  
  
#ifndef CUDA_UVM
  bpnn_layerforward_CUDA<<< grid, threads >>>(input_cuda,
	                                          output_hidden_cuda,
											  input_hidden_cuda,
											  hidden_partial_sum,
#else
  bpnn_layerforward_CUDA<<< grid, threads >>>(net->input_units,
	                                          output_hidden_cuda,
                                              input_weights_one_dim,
                                              partial_sum,
#endif
											  in,
											  hid);
 
  cudaThreadSynchronize();

  cudaError_t error = cudaGetLastError();
	if (error != cudaSuccess) {
		printf("bpnn kernel error: %s\n", cudaGetErrorString(error));
		exit(EXIT_FAILURE);
	}
  
#ifndef CUDA_UVM
  cudaMemcpy(partial_sum, hidden_partial_sum, num_blocks * WIDTH * sizeof(float), cudaMemcpyDeviceToHost);
#endif
     
  for (int j = 1; j <= hid; j++) {
    sum = 0.0;
    for (int k = 0; k < num_blocks; k++) {	
      sum += partial_sum[k * hid + j-1] ;
    }
	sum += net->input_weights[0][j];
	net-> hidden_units[j] = float(1.0 / (1.0 + exp(-sum)));
  }
  #endif

  bpnn_layerforward(net->hidden_units, net->output_units, net->hidden_weights, hid, out);
  bpnn_output_error(net->output_delta, net->target, net->output_units, out, &out_err);
  bpnn_hidden_error(net->hidden_delta, hid, net->output_delta, out, net->hidden_weights, net->hidden_units, &hid_err);  
  bpnn_adjust_weights(net->output_delta, out, net->hidden_units, hid, net->hidden_weights, net->hidden_prev_weights);

#ifdef CPU

  bpnn_adjust_weights(net->hidden_delta, hid, net->input_units, in, net->input_weights, net->input_prev_weights);

#endif  


#ifdef GPU

#ifndef CUDA_UVM
  cudaMalloc((void**) &hidden_delta_cuda, (hid + 1) * sizeof(float));
  cudaMalloc((void**) &input_prev_weights_cuda, (in + 1) * (hid + 1) * sizeof(float));

  cudaMemcpy(hidden_delta_cuda, net->hidden_delta, (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(input_prev_weights_cuda, input_weights_prev_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
  //cudaMemcpy(input_hidden_cuda, input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
#endif  
  total_size += (in + 1) * (hid + 1) * sizeof(float) + (hid + 1) * sizeof(float);
  printf("Total size: %llu\n", total_size);


#ifndef CUDA_UVM
  bpnn_adjust_weights_cuda<<< grid, threads >>>(hidden_delta_cuda,  
												hid, 
												input_cuda, 
#else
  bpnn_adjust_weights_cuda<<< grid, threads >>>(net->hidden_delta,  
												hid, 
												net->input_units, 
#endif
												in,
#ifndef CUDA_UVM
											    input_hidden_cuda,
												input_prev_weights_cuda
#else
                                                input_weights_one_dim,
                                                input_weights_prev_one_dim
#endif
												);

#ifndef CUDA_UVM
  cudaMemcpy(net->input_units, input_cuda, (in + 1) * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(input_weights_one_dim, input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyDeviceToHost);
#else
  cudaThreadSynchronize();
#endif
    
#ifndef CUDA_UVM
  cudaFree(input_cuda);
  cudaFree(input_hidden_cuda);
  //cudaFree(output_hidden_cuda);
  cudaFree(hidden_partial_sum);
  cudaFree(hidden_delta_cuda);
  cudaFree(input_prev_weights_cuda);
#endif
  
#ifndef CUDA_UVM
  free(input_weights_one_dim);
  free(partial_sum);
  free(input_weights_prev_one_dim);
#else
  cudaFree(input_weights_one_dim);
  cudaFree(partial_sum);
  cudaFree(input_weights_prev_one_dim);
#endif

#endif   
  
  cudaDeviceSynchronize();
  printf("Time: %f\n", gettime() - cur_time);
  
  

}
