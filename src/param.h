#define NUM_HASH 128 
#define MAX_LINE 30000 //Max line per line
#define BUCKET 16
#define SHINGLE_LEN 5

///////////////////////////////////////////////
#define MAX_BUCKET 100000 // MAX_BUCKET * MAX_BUCKET < GPU memory
#define NUM_KEY 10240 //MAX_BUCKET * NUM_KEY >> total line (=MAX_LINE * file_num)
#define C 1024 // Total file size / NUM_KEY * C < CPU memory
void set_param(const int num_file);
void get_param(int &_num_key, int &_max_bucket, int &_c);  