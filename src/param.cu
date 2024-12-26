#include <iostream>
#include <cstdlib>  // getenv
#include "mpi.h"

#include "param.h"

using namespace std;

#define MAX_BUCKET 100000 // MAX_BUCKET * MAX_BUCKET < GPU memory
#define NUM_KEY 10240 //MAX_BUCKET * NUM_KEY >> total line (=MAX_LINE * file_num)
 // Total file size / NUM_KEY * C < CPU memory

static int num_key=NUM_KEY;;
static int max_bucket=MAX_BUCKET;
static int c=C;

void set_param(const int num_file) {

    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank); 

    //get node info
    const char* local_size_str = std::getenv("OMPI_COMM_WORLD_LOCAL_SIZE");
    if (!local_size_str) return;

    int local_size = std::stoi(local_size_str);
    
    //get gpu info
    size_t free_mem = 0;
    size_t total_mem = 0;

    cudaError_t cuda_status = cudaMemGetInfo(&free_mem, &total_mem);
    if (cuda_status != cudaSuccess) {return;}

    // Get the number of available GPU devices
    int deviceCount = 0;
    cuda_status = cudaGetDeviceCount(&deviceCount);
    if (cuda_status != cudaSuccess) {return;}

     // Compute the maximum bucket size based on available GPU memory
    max_bucket=sqrt(free_mem*0.9/ ((local_size-1)/deviceCount+1));
    

     // Calculate the number of keys based on file size and bucket size
    num_key = max(2*num_file*MAX_LINE / max_bucket, int(std::pow(num_file*MAX_LINE, 1.0/2)*2));
    

    if (rank == 0) {
        std::cout  << "\n( The number of processes per node : " << local_size << ", The number of gpus per node: " << deviceCount << ")\n";
        std::cout  << "( max_bucket : " << max_bucket <<  ", num_key : " << num_key << ")\n" << std::endl;
    }

    // The number of keys to process simultaneously. It is adjusted based on CPU memory, with a default setting of 1024.
    c=C;
}

void get_param(int &_num_key, int &_max_bucket, int &_c) {
    _num_key=num_key;
    _max_bucket=max_bucket;
    _c=c;
}