// Copyright 2009, Andrew Corrigan, acorriga@gmu.edu
// This code is from the AIAA-2009-4001 paper

//#include <cutil.h>
#include <helper_cuda.h>
#include <helper_timer.h>
#include <iostream>
#include <fstream>

#define CUDA_UVM 
//#define CUDA_HST
//#define CUDA_HYB // work when defined with one of previous two macros
 
/*
 * Options 
 * 
 */ 
#define GAMMA 1.4f
//#define iterations 2000
#define iterations 20
// #ifndef block_length
// 	#define block_length 192
// #endif



#define NDIM 3
#define NNB 4

#define RK 3	// 3rd order RK
#define ff_mach 1.2f
#define deg_angle_of_attack 0.0f

/*
 * not options
 */

#ifdef RD_WG_SIZE_0_0
	#define BLOCK_SIZE_0 RD_WG_SIZE_0_0
#elif defined(RD_WG_SIZE_0)
	#define BLOCK_SIZE_0 RD_WG_SIZE_0
#elif defined(RD_WG_SIZE)
	#define BLOCK_SIZE_0 RD_WG_SIZE
#else
	#define BLOCK_SIZE_0 192
#endif

#ifdef RD_WG_SIZE_1_0
	#define BLOCK_SIZE_1 RD_WG_SIZE_1_0
#elif defined(RD_WG_SIZE_1)
	#define BLOCK_SIZE_1 RD_WG_SIZE_1
#elif defined(RD_WG_SIZE)
	#define BLOCK_SIZE_1 RD_WG_SIZE
#else
	#define BLOCK_SIZE_1 192
#endif

#ifdef RD_WG_SIZE_2_0
	#define BLOCK_SIZE_2 RD_WG_SIZE_2_0
#elif defined(RD_WG_SIZE_1)
	#define BLOCK_SIZE_2 RD_WG_SIZE_2
#elif defined(RD_WG_SIZE)
	#define BLOCK_SIZE_2 RD_WG_SIZE
#else
	#define BLOCK_SIZE_2 192
#endif

#ifdef RD_WG_SIZE_3_0
	#define BLOCK_SIZE_3 RD_WG_SIZE_3_0
#elif defined(RD_WG_SIZE_3)
	#define BLOCK_SIZE_3 RD_WG_SIZE_3
#elif defined(RD_WG_SIZE)
	#define BLOCK_SIZE_3 RD_WG_SIZE
#else
	#define BLOCK_SIZE_3 192
#endif

#ifdef RD_WG_SIZE_4_0
	#define BLOCK_SIZE_4 RD_WG_SIZE_4_0
#elif defined(RD_WG_SIZE_4)
	#define BLOCK_SIZE_4 RD_WG_SIZE_4
#elif defined(RD_WG_SIZE)
	#define BLOCK_SIZE_4 RD_WG_SIZE
#else
	#define BLOCK_SIZE_4 192
#endif



// #if block_length > 128
// #warning "the kernels may fail too launch on some systems if the block length is too large"
// #endif


#define VAR_DENSITY 0
#define VAR_MOMENTUM  1
#define VAR_DENSITY_ENERGY (VAR_MOMENTUM+NDIM)
#define NVAR (VAR_DENSITY_ENERGY+1)


/*
 * Generic functions
 */
template <typename T>
T* alloc(unsigned long long N)
{
	T* t;
#if defined (CUDA_UVM)
	checkCudaErrors(cudaMallocManaged((void**)&t, sizeof(T)*N));
#elif defined (CUDA_HST)
	checkCudaErrors(cudaMallocHost((void**)&t, sizeof(T)*N));
#else
	checkCudaErrors(cudaMalloc((void**)&t, sizeof(T)*N));
#endif
	return t;
}

template <typename T>
T* alloc_dev(int N)
{
	T* t;
	checkCudaErrors(cudaMalloc((void**)&t, sizeof(T)*N));
	return t;
}

template <typename T>
void dealloc(T* array)
{
	checkCudaErrors(cudaFree((void*)array));
}

template <typename T>
void copy(T* dst, T* src, int N)
{
	checkCudaErrors(cudaMemcpy((void*)dst, (void*)src, N*sizeof(T), cudaMemcpyDeviceToDevice));
}

template <typename T>
void upload(T* dst, T* src, int N)
{
	checkCudaErrors(cudaMemcpy((void*)dst, (void*)src, N*sizeof(T), cudaMemcpyHostToDevice));
}

template <typename T>
void download(T* dst, T* src, int N)
{
	checkCudaErrors(cudaMemcpy((void*)dst, (void*)src, N*sizeof(T), cudaMemcpyDeviceToHost));
}

void dump(float* variables, int nel, int nelr)
{
#if !defined (CUDA_UVM) && !defined (CUDA_HST)
	float* h_variables = new float[nelr*NVAR];
	download(h_variables, variables, nelr*NVAR);
#else
    float* h_variables = variables;
#endif

	{
		std::ofstream file("density");
		file << nel << " " << nelr << std::endl;
		for(int i = 0; i < nel; i++) file << h_variables[i + VAR_DENSITY*nelr] << std::endl;
	}


	{
		std::ofstream file("momentum");
		file << nel << " " << nelr << std::endl;
		for(int i = 0; i < nel; i++)
		{
			for(int j = 0; j != NDIM; j++)
				file << h_variables[i + (VAR_MOMENTUM+j)*nelr] << " ";
			file << std::endl;
		}
	}
	
	{
		std::ofstream file("density_energy");
		file << nel << " " << nelr << std::endl;
		for(int i = 0; i < nel; i++) file << h_variables[i + VAR_DENSITY_ENERGY*nelr] << std::endl;
	}
#if !defined (CUDA_UVM) && !defined (CUDA_HST)
	delete[] h_variables;
#endif
}

/*
 * Element-based Cell-centered FVM solver functions
 */
__constant__ float ff_variable[NVAR];
__constant__ float3 ff_flux_contribution_momentum_x[1];
__constant__ float3 ff_flux_contribution_momentum_y[1];
__constant__ float3 ff_flux_contribution_momentum_z[1];
__constant__ float3 ff_flux_contribution_density_energy[1];

__global__ void cuda_initialize_variables(int nelr, float* variables)
{
	const int i = (blockDim.x*blockIdx.x + threadIdx.x);
	for(int j = 0; j < NVAR; j++)
		variables[i + j*nelr] = ff_variable[j];
}
void initialize_variables(int nelr, float* variables)
{
	dim3 Dg(nelr / BLOCK_SIZE_1), Db(BLOCK_SIZE_1);
	cuda_initialize_variables<<<Dg, Db>>>(nelr, variables);
	getLastCudaError("initialize_variables failed");
}

__device__ __host__ inline void compute_flux_contribution(float& density, float3& momentum, float& density_energy, float& pressure, float3& velocity, float3& fc_momentum_x, float3& fc_momentum_y, float3& fc_momentum_z, float3& fc_density_energy)
{
	fc_momentum_x.x = velocity.x*momentum.x + pressure;
	fc_momentum_x.y = velocity.x*momentum.y;
	fc_momentum_x.z = velocity.x*momentum.z;
	
	
	fc_momentum_y.x = fc_momentum_x.y;
	fc_momentum_y.y = velocity.y*momentum.y + pressure;
	fc_momentum_y.z = velocity.y*momentum.z;

	fc_momentum_z.x = fc_momentum_x.z;
	fc_momentum_z.y = fc_momentum_y.z;
	fc_momentum_z.z = velocity.z*momentum.z + pressure;

	float de_p = density_energy+pressure;
	fc_density_energy.x = velocity.x*de_p;
	fc_density_energy.y = velocity.y*de_p;
	fc_density_energy.z = velocity.z*de_p;
}

__device__ inline void compute_velocity(float& density, float3& momentum, float3& velocity)
{
	velocity.x = momentum.x / density;
	velocity.y = momentum.y / density;
	velocity.z = momentum.z / density;
}
	
__device__ inline float compute_speed_sqd(float3& velocity)
{
	return velocity.x*velocity.x + velocity.y*velocity.y + velocity.z*velocity.z;
}

__device__ inline float compute_pressure(float& density, float& density_energy, float& speed_sqd)
{
	return (float(GAMMA)-float(1.0f))*(density_energy - float(0.5f)*density*speed_sqd);
}

__device__ inline float compute_speed_of_sound(float& density, float& pressure)
{
	return sqrtf(float(GAMMA)*pressure/density);
}

__global__ void cuda_compute_step_factor(int nelr, float* variables, float* areas, float* step_factors)
{
	const int i = (blockDim.x*blockIdx.x + threadIdx.x);

	float density = variables[i + VAR_DENSITY*nelr];
	float3 momentum;
	momentum.x = variables[i + (VAR_MOMENTUM+0)*nelr];
	momentum.y = variables[i + (VAR_MOMENTUM+1)*nelr];
	momentum.z = variables[i + (VAR_MOMENTUM+2)*nelr];
	
	float density_energy = variables[i + VAR_DENSITY_ENERGY*nelr];
	
	float3 velocity;       compute_velocity(density, momentum, velocity);
	float speed_sqd      = compute_speed_sqd(velocity);
	float pressure       = compute_pressure(density, density_energy, speed_sqd);
	float speed_of_sound = compute_speed_of_sound(density, pressure);

	// dt = float(0.5f) * sqrtf(areas[i]) /  (||v|| + c).... but when we do time stepping, this later would need to be divided by the area, so we just do it all at once
	step_factors[i] = float(0.5f) / (sqrtf(areas[i]) * (sqrtf(speed_sqd) + speed_of_sound));
}
void compute_step_factor(int nelr, float* variables, float* areas, float* step_factors)
{
	dim3 Dg(nelr / BLOCK_SIZE_2), Db(BLOCK_SIZE_2);
	cuda_compute_step_factor<<<Dg, Db>>>(nelr, variables, areas, step_factors);		
	getLastCudaError("compute_step_factor failed");
}

/*
 *
 *
*/
#if defined (CUDA_HYB)
__global__ void cuda_compute_flux(int nelr, int* elements_surrounding_elements, float* normals, float* variables, float* fluxes, float* normals2, unsigned long long ele_dev_size)
#else
__global__ void cuda_compute_flux(int nelr, int* elements_surrounding_elements, float* normals, float* variables, float* fluxes)
#endif
{
	const float smoothing_coefficient = float(0.2f);
	const int i = (blockDim.x*blockIdx.x + threadIdx.x);
	
	int j, nb;
	float3 normal; float normal_len;
	float factor;
	
	float density_i = variables[i + VAR_DENSITY*nelr];
	float3 momentum_i;
	momentum_i.x = variables[i + (VAR_MOMENTUM+0)*nelr];
	momentum_i.y = variables[i + (VAR_MOMENTUM+1)*nelr];
	momentum_i.z = variables[i + (VAR_MOMENTUM+2)*nelr];

	float density_energy_i = variables[i + VAR_DENSITY_ENERGY*nelr];

	float3 velocity_i;             				compute_velocity(density_i, momentum_i, velocity_i);
	float speed_sqd_i                          = compute_speed_sqd(velocity_i);
	float speed_i                              = sqrtf(speed_sqd_i);
	float pressure_i                           = compute_pressure(density_i, density_energy_i, speed_sqd_i);
	float speed_of_sound_i                     = compute_speed_of_sound(density_i, pressure_i);
	float3 flux_contribution_i_momentum_x, flux_contribution_i_momentum_y, flux_contribution_i_momentum_z;
	float3 flux_contribution_i_density_energy;	
	compute_flux_contribution(density_i, momentum_i, density_energy_i, pressure_i, velocity_i, flux_contribution_i_momentum_x, flux_contribution_i_momentum_y, flux_contribution_i_momentum_z, flux_contribution_i_density_energy);
	
	float flux_i_density = float(0.0f);
	float3 flux_i_momentum;
	flux_i_momentum.x = float(0.0f);
	flux_i_momentum.y = float(0.0f);
	flux_i_momentum.z = float(0.0f);
	float flux_i_density_energy = float(0.0f);
		
	float3 velocity_nb;
	float density_nb, density_energy_nb;
	float3 momentum_nb;
	float3 flux_contribution_nb_momentum_x, flux_contribution_nb_momentum_y, flux_contribution_nb_momentum_z;
	float3 flux_contribution_nb_density_energy;	
	float speed_sqd_nb, speed_of_sound_nb, pressure_nb;
	
	#pragma unroll
	for(j = 0; j < NNB; j++)
	{
		nb = elements_surrounding_elements[i + j*nelr];
#if defined (CUDA_HYB)
        unsigned long long idx = i + (j + 0*NNB)*nelr;
        if (idx < ele_dev_size)
		  normal.x = normals[idx];
        else
		  normal.x = normals2[idx - ele_dev_size];
        idx += NNB*nelr;
        if (idx < ele_dev_size)
		  normal.y = normals[idx];
        else
		  normal.y = normals2[idx - ele_dev_size];
        idx += NNB*nelr;
        if (idx < ele_dev_size)
		  normal.z = normals[idx];
        else
		  normal.z = normals2[idx - ele_dev_size];
#else
		normal.x = normals[i + (j + 0*NNB)*nelr];
		normal.y = normals[i + (j + 1*NNB)*nelr];
		normal.z = normals[i + (j + 2*NNB)*nelr];
#endif
		normal_len = sqrtf(normal.x*normal.x + normal.y*normal.y + normal.z*normal.z);
		
		if(nb >= 0) 	// a legitimate neighbor
		{
			density_nb = variables[nb + VAR_DENSITY*nelr];
			momentum_nb.x = variables[nb + (VAR_MOMENTUM+0)*nelr];
			momentum_nb.y = variables[nb + (VAR_MOMENTUM+1)*nelr];
			momentum_nb.z = variables[nb + (VAR_MOMENTUM+2)*nelr];
			density_energy_nb = variables[nb + VAR_DENSITY_ENERGY*nelr];
												compute_velocity(density_nb, momentum_nb, velocity_nb);
			speed_sqd_nb                      = compute_speed_sqd(velocity_nb);
			pressure_nb                       = compute_pressure(density_nb, density_energy_nb, speed_sqd_nb);
			speed_of_sound_nb                 = compute_speed_of_sound(density_nb, pressure_nb);
			                                    compute_flux_contribution(density_nb, momentum_nb, density_energy_nb, pressure_nb, velocity_nb, flux_contribution_nb_momentum_x, flux_contribution_nb_momentum_y, flux_contribution_nb_momentum_z, flux_contribution_nb_density_energy);
			
			// artificial viscosity
			factor = -normal_len*smoothing_coefficient*float(0.5f)*(speed_i + sqrtf(speed_sqd_nb) + speed_of_sound_i + speed_of_sound_nb);
			flux_i_density += factor*(density_i-density_nb);
			flux_i_density_energy += factor*(density_energy_i-density_energy_nb);
			flux_i_momentum.x += factor*(momentum_i.x-momentum_nb.x);
			flux_i_momentum.y += factor*(momentum_i.y-momentum_nb.y);
			flux_i_momentum.z += factor*(momentum_i.z-momentum_nb.z);

			// accumulate cell-centered fluxes
			factor = float(0.5f)*normal.x;
			flux_i_density += factor*(momentum_nb.x+momentum_i.x);
			flux_i_density_energy += factor*(flux_contribution_nb_density_energy.x+flux_contribution_i_density_energy.x);
			flux_i_momentum.x += factor*(flux_contribution_nb_momentum_x.x+flux_contribution_i_momentum_x.x);
			flux_i_momentum.y += factor*(flux_contribution_nb_momentum_y.x+flux_contribution_i_momentum_y.x);
			flux_i_momentum.z += factor*(flux_contribution_nb_momentum_z.x+flux_contribution_i_momentum_z.x);
			
			factor = float(0.5f)*normal.y;
			flux_i_density += factor*(momentum_nb.y+momentum_i.y);
			flux_i_density_energy += factor*(flux_contribution_nb_density_energy.y+flux_contribution_i_density_energy.y);
			flux_i_momentum.x += factor*(flux_contribution_nb_momentum_x.y+flux_contribution_i_momentum_x.y);
			flux_i_momentum.y += factor*(flux_contribution_nb_momentum_y.y+flux_contribution_i_momentum_y.y);
			flux_i_momentum.z += factor*(flux_contribution_nb_momentum_z.y+flux_contribution_i_momentum_z.y);
			
			factor = float(0.5f)*normal.z;
			flux_i_density += factor*(momentum_nb.z+momentum_i.z);
			flux_i_density_energy += factor*(flux_contribution_nb_density_energy.z+flux_contribution_i_density_energy.z);
			flux_i_momentum.x += factor*(flux_contribution_nb_momentum_x.z+flux_contribution_i_momentum_x.z);
			flux_i_momentum.y += factor*(flux_contribution_nb_momentum_y.z+flux_contribution_i_momentum_y.z);
			flux_i_momentum.z += factor*(flux_contribution_nb_momentum_z.z+flux_contribution_i_momentum_z.z);
		}
		else if(nb == -1)	// a wing boundary
		{
			flux_i_momentum.x += normal.x*pressure_i;
			flux_i_momentum.y += normal.y*pressure_i;
			flux_i_momentum.z += normal.z*pressure_i;
		}
		else if(nb == -2) // a far field boundary
		{
			factor = float(0.5f)*normal.x;
			flux_i_density += factor*(ff_variable[VAR_MOMENTUM+0]+momentum_i.x);
			flux_i_density_energy += factor*(ff_flux_contribution_density_energy[0].x+flux_contribution_i_density_energy.x);
			flux_i_momentum.x += factor*(ff_flux_contribution_momentum_x[0].x + flux_contribution_i_momentum_x.x);
			flux_i_momentum.y += factor*(ff_flux_contribution_momentum_y[0].x + flux_contribution_i_momentum_y.x);
			flux_i_momentum.z += factor*(ff_flux_contribution_momentum_z[0].x + flux_contribution_i_momentum_z.x);
			
			factor = float(0.5f)*normal.y;
			flux_i_density += factor*(ff_variable[VAR_MOMENTUM+1]+momentum_i.y);
			flux_i_density_energy += factor*(ff_flux_contribution_density_energy[0].y+flux_contribution_i_density_energy.y);
			flux_i_momentum.x += factor*(ff_flux_contribution_momentum_x[0].y + flux_contribution_i_momentum_x.y);
			flux_i_momentum.y += factor*(ff_flux_contribution_momentum_y[0].y + flux_contribution_i_momentum_y.y);
			flux_i_momentum.z += factor*(ff_flux_contribution_momentum_z[0].y + flux_contribution_i_momentum_z.y);

			factor = float(0.5f)*normal.z;
			flux_i_density += factor*(ff_variable[VAR_MOMENTUM+2]+momentum_i.z);
			flux_i_density_energy += factor*(ff_flux_contribution_density_energy[0].z+flux_contribution_i_density_energy.z);
			flux_i_momentum.x += factor*(ff_flux_contribution_momentum_x[0].z + flux_contribution_i_momentum_x.z);
			flux_i_momentum.y += factor*(ff_flux_contribution_momentum_y[0].z + flux_contribution_i_momentum_y.z);
			flux_i_momentum.z += factor*(ff_flux_contribution_momentum_z[0].z + flux_contribution_i_momentum_z.z);

		}
	}

	fluxes[i + VAR_DENSITY*nelr] = flux_i_density;
	fluxes[i + (VAR_MOMENTUM+0)*nelr] = flux_i_momentum.x;
	fluxes[i + (VAR_MOMENTUM+1)*nelr] = flux_i_momentum.y;
	fluxes[i + (VAR_MOMENTUM+2)*nelr] = flux_i_momentum.z;
	fluxes[i + VAR_DENSITY_ENERGY*nelr] = flux_i_density_energy;
}
#if defined (CUDA_HYB)
void compute_flux(int nelr, int* elements_surrounding_elements, float* normals, float* variables, float* fluxes, float* normals2, unsigned long long ele_dev_size)
#else
void compute_flux(int nelr, int* elements_surrounding_elements, float* normals, float* variables, float* fluxes)
#endif
{
	dim3 Dg(nelr / BLOCK_SIZE_3), Db(BLOCK_SIZE_3);
#if defined (CUDA_HYB)
	cuda_compute_flux<<<Dg,Db>>>(nelr, elements_surrounding_elements, normals, variables, fluxes, normals2, ele_dev_size);
#else
	cuda_compute_flux<<<Dg,Db>>>(nelr, elements_surrounding_elements, normals, variables, fluxes);
#endif
	getLastCudaError("compute_flux failed");
}

__global__ void cuda_time_step(int j, int nelr, float* old_variables, float* variables, float* step_factors, float* fluxes)
{
	const int i = (blockDim.x*blockIdx.x + threadIdx.x);

	float factor = step_factors[i]/float(RK+1-j);

	variables[i + VAR_DENSITY*nelr] = old_variables[i + VAR_DENSITY*nelr] + factor*fluxes[i + VAR_DENSITY*nelr];
	variables[i + VAR_DENSITY_ENERGY*nelr] = old_variables[i + VAR_DENSITY_ENERGY*nelr] + factor*fluxes[i + VAR_DENSITY_ENERGY*nelr];
	variables[i + (VAR_MOMENTUM+0)*nelr] = old_variables[i + (VAR_MOMENTUM+0)*nelr] + factor*fluxes[i + (VAR_MOMENTUM+0)*nelr];
	variables[i + (VAR_MOMENTUM+1)*nelr] = old_variables[i + (VAR_MOMENTUM+1)*nelr] + factor*fluxes[i + (VAR_MOMENTUM+1)*nelr];	
	variables[i + (VAR_MOMENTUM+2)*nelr] = old_variables[i + (VAR_MOMENTUM+2)*nelr] + factor*fluxes[i + (VAR_MOMENTUM+2)*nelr];	
}
void time_step(int j, int nelr, float* old_variables, float* variables, float* step_factors, float* fluxes)
{
	dim3 Dg(nelr / BLOCK_SIZE_4), Db(BLOCK_SIZE_4);
	cuda_time_step<<<Dg,Db>>>(j, nelr, old_variables, variables, step_factors, fluxes);
	getLastCudaError("update failed");
}

/*
 * Main function
 */
int main(int argc, char** argv)
{
  printf("WG size of kernel:initialize = %d, WG size of kernel:compute_step_factor = %d, WG size of kernel:compute_flux = %d, WG size of kernel:time_step = %d\n", BLOCK_SIZE_1, BLOCK_SIZE_2, BLOCK_SIZE_3, BLOCK_SIZE_4);

	if (argc < 3)
	{
		std::cout << "specify data file name" << std::endl;
		return 0;
	}
	const char* data_file_name = argv[1];
    int input_time = atoi(argv[2]);
	
	cudaDeviceProp prop;
	int dev;
	
	checkCudaErrors(cudaSetDevice(0));
	checkCudaErrors(cudaGetDevice(&dev));
	checkCudaErrors(cudaGetDeviceProperties(&prop, dev));
	
	printf("Name:                     %s\n", prop.name);

	// set far field conditions and load them into constant memory on the gpu
	{
		float h_ff_variable[NVAR];
		const float angle_of_attack = float(3.1415926535897931 / 180.0f) * float(deg_angle_of_attack);
		
		h_ff_variable[VAR_DENSITY] = float(1.4);
		
		float ff_pressure = float(1.0f);
		float ff_speed_of_sound = sqrt(GAMMA*ff_pressure / h_ff_variable[VAR_DENSITY]);
		float ff_speed = float(ff_mach)*ff_speed_of_sound;
		
		float3 ff_velocity;
		ff_velocity.x = ff_speed*float(cos((float)angle_of_attack));
		ff_velocity.y = ff_speed*float(sin((float)angle_of_attack));
		ff_velocity.z = 0.0f;
		
		h_ff_variable[VAR_MOMENTUM+0] = h_ff_variable[VAR_DENSITY] * ff_velocity.x;
		h_ff_variable[VAR_MOMENTUM+1] = h_ff_variable[VAR_DENSITY] * ff_velocity.y;
		h_ff_variable[VAR_MOMENTUM+2] = h_ff_variable[VAR_DENSITY] * ff_velocity.z;
				
		h_ff_variable[VAR_DENSITY_ENERGY] = h_ff_variable[VAR_DENSITY]*(float(0.5f)*(ff_speed*ff_speed)) + (ff_pressure / float(GAMMA-1.0f));

		float3 h_ff_momentum;
		h_ff_momentum.x = *(h_ff_variable+VAR_MOMENTUM+0);
		h_ff_momentum.y = *(h_ff_variable+VAR_MOMENTUM+1);
		h_ff_momentum.z = *(h_ff_variable+VAR_MOMENTUM+2);
		float3 h_ff_flux_contribution_momentum_x;
		float3 h_ff_flux_contribution_momentum_y;
		float3 h_ff_flux_contribution_momentum_z;
		float3 h_ff_flux_contribution_density_energy;
		compute_flux_contribution(h_ff_variable[VAR_DENSITY], h_ff_momentum, h_ff_variable[VAR_DENSITY_ENERGY], ff_pressure, ff_velocity, h_ff_flux_contribution_momentum_x, h_ff_flux_contribution_momentum_y, h_ff_flux_contribution_momentum_z, h_ff_flux_contribution_density_energy);

		// copy far field conditions to the gpu
		checkCudaErrors( cudaMemcpyToSymbol(ff_variable,          h_ff_variable,          NVAR*sizeof(float)) );
		checkCudaErrors( cudaMemcpyToSymbol(ff_flux_contribution_momentum_x, &h_ff_flux_contribution_momentum_x, sizeof(float3)) );
		checkCudaErrors( cudaMemcpyToSymbol(ff_flux_contribution_momentum_y, &h_ff_flux_contribution_momentum_y, sizeof(float3)) );
		checkCudaErrors( cudaMemcpyToSymbol(ff_flux_contribution_momentum_z, &h_ff_flux_contribution_momentum_z, sizeof(float3)) );
		
		checkCudaErrors( cudaMemcpyToSymbol(ff_flux_contribution_density_energy, &h_ff_flux_contribution_density_energy, sizeof(float3)) );		
	}
	int nel;
	int nelr;
	
	// read in domain geometry
	float* areas;
	int* elements_surrounding_elements;
	float* normals;
#if defined (CUDA_HYB)
    unsigned long long ele_dev_size;
    float* normals2 = NULL;
#endif
	{
		std::ifstream file(data_file_name);
	
		file >> nel;
		nelr = BLOCK_SIZE_0*((nel * input_time / BLOCK_SIZE_0 )+ std::min(1, (nel * input_time) % BLOCK_SIZE_0));

#if defined (CUDA_HYB)
	    areas = alloc_dev<float>(nelr);
	    elements_surrounding_elements = alloc_dev<int>(nelr*NNB);
        long long avail_size = 14 * 1024 * 1024 * 1024L - sizeof(float)*nelr*NVAR*3 + sizeof(float)*nelr*2 - sizeof(int)*nelr*NNB;
        if (avail_size <= 0) {
	      std::cout << "Input is too large for HYB." << std::endl;
	      return 0;
        }
        ele_dev_size = avail_size / sizeof(float);
        unsigned long long ele_um_size = 0;
        if (ele_dev_size >= nelr*NDIM*NNB) {
	      std::cout << "Input is too small for HYB." << std::endl;
          ele_dev_size = nelr*NDIM*NNB;
        } else
          ele_um_size = nelr*NDIM*NNB - ele_dev_size;
	    normals = alloc_dev<float>(ele_dev_size);
        if (ele_um_size)
	      normals2 = alloc<float>(ele_um_size);
#else
	    areas = alloc<float>(nelr);
	    elements_surrounding_elements = alloc<int>(nelr*NNB);
        unsigned long long size = (unsigned long long)nelr*NDIM*NNB;
	    normals = alloc<float>(size);
#endif

#if defined (CUDA_HYB)
		float* h_areas = new float[nelr];
		int* h_elements_surrounding_elements = new int[nelr*NNB];
		float* h_normals = new float[ele_dev_size];
		float* h_normals2 = normals2;
#elif defined (CUDA_UVM) || defined (CUDA_HST)
		float* h_areas = areas;
		int* h_elements_surrounding_elements = elements_surrounding_elements;
		float* h_normals = normals;
#else
		float* h_areas = new float[nelr];
		int* h_elements_surrounding_elements = new int[nelr*NNB];
		float* h_normals = new float[nelr*NDIM*NNB];
#endif

				
		// read in data
		for(int i = 0; i < nel; i++)
		{
			file >> h_areas[i];
			for(int j = 0; j < NNB; j++)
			{
				file >> h_elements_surrounding_elements[i + j*nelr];
				if(h_elements_surrounding_elements[i+j*nelr] < 0) h_elements_surrounding_elements[i+j*nelr] = -1;
				h_elements_surrounding_elements[i + j*nelr]--; //it's coming in with Fortran numbering				
				
				for(int k = 0; k < NDIM; k++)
				{
#if defined (CUDA_HYB)
                    unsigned long long idx = i + (j + k*NNB)*nelr;
                    if (idx < ele_dev_size) {
					  file >> h_normals[idx];
					  h_normals[idx] = -h_normals[idx];
                    } else {
					  file >> h_normals2[idx - ele_dev_size];
					  h_normals2[idx - ele_dev_size] = -h_normals2[idx - ele_dev_size];
                    }
#else
					file >> h_normals[i + (j + k*NNB)*nelr];
					h_normals[i + (j + k*NNB)*nelr] = -h_normals[i + (j + k*NNB)*nelr];
#endif
				}
			}
		}
        file.close();
        for (int nn = 1; nn < input_time; nn++)
        {
		    for(int i = 0; i < nel; i++)
		    {
		    	h_areas[i + nn*nel] = h_areas[i];
		    	for(int j = 0; j < NNB; j++)
		    	{
		    		h_elements_surrounding_elements[i + j*nelr + nn*nel] = h_elements_surrounding_elements[i + j*nelr];
		    		
		    		for(int k = 0; k < NDIM; k++)
		    		{
#if defined (CUDA_HYB)
                      unsigned long long idx = i + (j + k*NNB)*nelr + nn*nel;
                      unsigned long long idx2 = i + (j + k*NNB)*nelr;
                      if (idx < ele_dev_size) {
                        if (idx2 < ele_dev_size)
		    			  h_normals[idx] = h_normals[idx2];
                        else
		    			  h_normals[idx] = h_normals2[idx2 - ele_dev_size];
                      } else {
                        if (idx2 < ele_dev_size)
		    			  h_normals2[idx - ele_dev_size] = h_normals[idx2];
                        else
		    			  h_normals2[idx - ele_dev_size] = h_normals2[idx2 - ele_dev_size];
                      }
#else
		    			h_normals[i + (j + k*NNB)*nelr + nn*nel] = h_normals[i + (j + k*NNB)*nelr];
#endif
		    		}
		    	}
		    }
        }
        nel *= input_time;
		
		// fill in remaining data
		int last = nel-1;
		for(int i = nel; i < nelr; i++)
		{
			h_areas[i] = h_areas[last];
			for(int j = 0; j < NNB; j++)
			{
				// duplicate the last element
				h_elements_surrounding_elements[i + j*nelr] = h_elements_surrounding_elements[last + j*nelr];	
#if defined (CUDA_HYB)
				for(int k = 0; k < NDIM; k++) {
                  unsigned long long idx = i + (j + k*NNB)*nelr;
                  if (idx < ele_dev_size) {
                    if (last + (j + k*NNB)*nelr < ele_dev_size)
                      h_normals[idx] = h_normals[last + (j + k*NNB)*nelr];
                    else
                      h_normals[idx] = h_normals2[last + (j + k*NNB)*nelr - ele_dev_size];
                  }
                  else {
                    if (last + (j + k*NNB)*nelr < ele_dev_size)
                      h_normals2[idx - ele_dev_size] = h_normals[last + (j + k*NNB)*nelr];
                    else
                      h_normals2[idx - ele_dev_size] = h_normals2[last + (j + k*NNB)*nelr - ele_dev_size];
                  }
                }
#else
				for(int k = 0; k < NDIM; k++) h_normals[i + (j + k*NNB)*nelr] = h_normals[last + (j + k*NNB)*nelr];
#endif
			}
		}
		
#if defined (CUDA_HYB)
		upload<float>(areas, h_areas, nelr);

		upload<int>(elements_surrounding_elements, h_elements_surrounding_elements, nelr*NNB);

		upload<float>(normals, h_normals, ele_dev_size);
				
		delete[] h_areas;
		delete[] h_elements_surrounding_elements;
		delete[] h_normals;
#elif !defined (CUDA_UVM) && !defined (CUDA_HST)
		upload<float>(areas, h_areas, nelr);

		upload<int>(elements_surrounding_elements, h_elements_surrounding_elements, nelr*NNB);

		upload<float>(normals, h_normals, nelr*NDIM*NNB);
				
		delete[] h_areas;
		delete[] h_elements_surrounding_elements;
		delete[] h_normals;
#endif
	}

	// Create arrays and set initial conditions
	float* variables = alloc<float>(nelr*NVAR);
	initialize_variables(nelr, variables);

	float* old_variables = alloc<float>(nelr*NVAR);   	
	float* fluxes = alloc<float>(nelr*NVAR);
	float* step_factors = alloc<float>(nelr); 

	// make sure all memory is floatly allocated before we start timing
	initialize_variables(nelr, old_variables);
	initialize_variables(nelr, fluxes);
	cudaMemset( (void*) step_factors, 0, sizeof(float)*nelr );
	// make sure CUDA isn't still doing something before we start timing
	cudaThreadSynchronize();

    unsigned long long total_size = sizeof(float)*nelr // area
      + sizeof(int)*nelr*NNB + sizeof(float)*nelr*NDIM*NNB;
    std::cout << "Input size: " << total_size << "\n"; 
    total_size += sizeof(float)*nelr*NVAR*3 + sizeof(float)*nelr;
    std::cout << "Total size: " << total_size << "\n"; 

	// these need to be computed the first time in order to compute time step
	std::cout << "Starting..." << std::endl;

	StopWatchInterface *timer = 0;
	  //	unsigned int timer = 0;

	// CUT_SAFE_CALL( cutCreateTimer( &timer));
	// CUT_SAFE_CALL( cutStartTimer( timer));
	sdkCreateTimer(&timer); 
	sdkStartTimer(&timer); 
	// Begin iterations
	for(int i = 0; i < iterations; i++)
	{
		copy<float>(old_variables, variables, nelr*NVAR);
		
		// for the first iteration we compute the time step
		compute_step_factor(nelr, variables, areas, step_factors);
		getLastCudaError("compute_step_factor failed");
		
		for(int j = 0; j < RK; j++)
		{
#if defined (CUDA_HYB)
			compute_flux(nelr, elements_surrounding_elements, normals, variables, fluxes, normals2, ele_dev_size);
#else
			compute_flux(nelr, elements_surrounding_elements, normals, variables, fluxes);
#endif
			getLastCudaError("compute_flux failed");			
			time_step(j, nelr, old_variables, variables, step_factors, fluxes);
			getLastCudaError("time_step failed");			
		}
	}

	cudaThreadSynchronize();
	//	CUT_SAFE_CALL( cutStopTimer(timer) );  
	sdkStopTimer(&timer); 

	std::cout  << (sdkGetAverageTimerValue(&timer)/1000.0)  / iterations << " seconds per iteration" << std::endl;

	//std::cout << "Saving solution..." << std::endl;
	//dump(variables, nel, nelr);
	//std::cout << "Saved solution..." << std::endl;

	
	std::cout << "Cleaning up..." << std::endl;
	//dealloc<float>(areas);
	//dealloc<int>(elements_surrounding_elements);
	//dealloc<float>(normals);
	//
	//dealloc<float>(variables);
	//dealloc<float>(old_variables);
	//dealloc<float>(fluxes);
	//dealloc<float>(step_factors);

	std::cout << "Done..." << std::endl;

	return 0;
}
