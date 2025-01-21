#include <iostream>
#include <cstring>
#include <vector>
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>

#include "mpi.h"
#include "param.h"
#include "util.h"
#include "lsh.h"

using namespace std;

int main(int argc, char* argv[]) {
    MPI_Init(&argc, &argv); // Initialize MPI
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank); // Get rank of the process
    MPI_Comm_size(MPI_COMM_WORLD, &size); // Get total number of processes


    int deviceCount = 0;
    cudaError_t cuda_status = cudaGetDeviceCount(&deviceCount); // Get number of GPUs
    if (cuda_status != cudaSuccess) {return 1;}
    cudaSetDevice(rank % deviceCount); // Assign GPU to the process

    if (argc != 3) {
        if (rank == 0)
            std::cerr << "Directory path require" << std::endl;
        MPI_Finalize();
        return 1;
    }

    std::string folderPath = argv[1]; // Input folder path
    std::string outputPath = argv[2]; // Output folder path


    vector<string> file_list;
    getFileList(file_list, folderPath); // Get list of files in the input folder

    // Filter out unwanted files
    file_list.erase(
        std::remove_if(file_list.begin(), file_list.end(),
            [](const string& path) {
                std::filesystem::path fp(path);
                std::string filename = fp.filename().string();
                
                // Skip if:
                // 1. File starts with . (hidden files)
                // 2. File starts with _ (temporary files)
                // 3. File is not a regular file
                // 4. File is empty
                return filename[0] == '.' || 
                       filename[0] == '_' ||
                       !std::filesystem::is_regular_file(fp) ||
                       std::filesystem::file_size(fp) == 0;
            }
        ),
        file_list.end()
    );

    sort(file_list.begin(), file_list.end()); // Sort files alphabetically

    int num_file = file_list.size(); // Total number of files
    int files_per_process = (num_file + size - 1) / size; // Files assigned per process

    int start_index = rank * files_per_process; // Start index for the process
    int end_index = min(start_index + files_per_process, num_file); // End index for the process

    // Initialize parameters for LSH
    int num_hash = NUM_HASH;
    int b = BUCKET;
    int shingle_len = SHINGLE_LEN;
    init_lsh_cuda(num_hash, shingle_len, b, 777984, 0.8, num_file); //num_hash, shingle_len, random_seed
    if(!rank) generate_file_init(outputPath);

    int *file_size= (int*)malloc(sizeof(int) * files_per_process * size);

    // Generate Minhash signature matrix and Calculate the bucket IDs of each band.
    if (rank == 0) {
        std::cout << "Start Minhash Generation.." << std::endl;
    }

    auto time1 = std::chrono::high_resolution_clock::now();
    for (int i=start_index; i < end_index; i++) {
        const string &fp=file_list[i];
        // Check if minhash file already exists
        std::filesystem::path inputPath(fp);
        std::string filename = inputPath.stem().string();
        std::string hashFilename = filename + "_hashresult.bin";
        std::filesystem::path outputDir(outputPath);
        std::filesystem::path hashFilePath = outputDir / hashFilename;

        if (std::filesystem::exists(hashFilePath)) {
            // Read existing file size from the hash file
            std::ifstream inFile(hashFilePath, std::ios::binary | std::ios::ate);
            if (inFile) {
                size_t fileSize = inFile.tellg();
                file_size[i] = fileSize / (sizeof(unsigned int) * (num_hash + b));
                inFile.close();
                continue;
            }
        }
        // Generate new minhash if file doesn't exist
        lsh_cuda(fp, outputPath, file_size[i]);
    }

    // Gather file sizes from all processes
    MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, file_size, files_per_process, MPI_INT, MPI_COMM_WORLD);
    auto time2 = std::chrono::high_resolution_clock::now();

    std::chrono::duration<double> elapsed1 = time2 - time1;
    
    // Calculate time taken for MinHash
    if (rank == 0) {
        std::cout << "Min Hash total time: " << elapsed1.count() << " seconds" << std::endl;
        std::cout << "  - File read time: " << get_total_file_read_time_lsh() << " seconds" << std::endl;
        std::cout << "  - Computation time(c2g): " << c2g() << " seconds" << std::endl;
        std::cout << "  - Computation time: " << get_total_computation_time_lsh() << " seconds" << std::endl;
        std::cout << "  - Computation time(g2c): " << g2c() << " seconds" << std::endl;
        std::cout << "  - File write time: " << get_total_file_write_time_lsh() << " seconds\n" << std::endl;
    }

    // Comparison phase
    if (rank == 0) {
        std::cout << "Start Comparison.." << std::endl;
    }
    time1 = std::chrono::high_resolution_clock::now();
    compare_lsh_cuda(file_list, outputPath, num_file, file_size, rank, size);
    MPI_Barrier(MPI_COMM_WORLD);
    time2 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed2 = time2 - time1;
    if (rank == 0) {
        std::cout << "\nComparison total time: " << elapsed2.count() << " seconds" << std::endl;
        print_cmp_time_lsh();
    }

    time1 = std::chrono::high_resolution_clock::now();
    merge_union(rank, size); // Merge results across processes
    time2 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed3 = time2 - time1;


    MPI_Barrier(MPI_COMM_WORLD);


    if (rank == 0) {
        std::cout << "Saving the final cleaned dataset.." << std::endl;
    }
    time1 = std::chrono::high_resolution_clock::now();
    for (int i=start_index; i < end_index; i++) {
        const string &fp=file_list[i];
        generate_file(fp, i, outputPath); 
    }
    // save the final deduplicated dataset 
    MPI_Barrier(MPI_COMM_WORLD);
    time2 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed4 = time2 - time1;
    


    // Print total times for all phases
    if (rank == 0) {
        printf("==================================================\n");
        std::cout << "Min Hash total time: " << elapsed1.count() << " seconds" << std::endl;
        std::cout << "Comparison total time: " << elapsed2.count() << " seconds" << std::endl;
        std::cout << "Union total time: " << elapsed3.count() << " seconds" << std::endl;
        std::cout << "File generate time: " << elapsed4.count() << " seconds" << std::endl;
        std::cout << "Total time: " << elapsed1.count()+elapsed2.count()+elapsed3.count()+elapsed4.count() << " seconds" << std::endl;
    }

    finalize_lsh();

    MPI_Finalize();
    return 0;
}
