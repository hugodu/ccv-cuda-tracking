#ifndef _API_H
#define _API_H

typedef enum {
	GPU_MEMORY_HOST = 0,
	GPU_MEMORY_PINNED_WRITE_COMBINED,
	GPU_MEMORY_PINNED,
} gpu_context_memory_t;

typedef enum {
	GPU_OK = 0,
	GPU_ERR_MEM,
	GPU_ERR_CUDA
} gpu_error_t;

typedef struct
{
	int height;
	int width;
	int nchannels;
	int size ;
	unsigned char *output_buffer_4;	
	unsigned char *gpu_buffer_4;
	unsigned char *output_buffer_1;
	unsigned char *gpu_buffer_1;
	gpu_context_memory_t mem_flag;
} gpu_context_t;

const char *gpu_error();

gpu_error_t checkCudaError();

gpu_error_t gpu_context_create(gpu_context_t **ctx);

gpu_error_t gpu_context_init(gpu_context_t *ctx, int host_height, int host_width, int host_nchannels, gpu_context_memory_t host_flag);

gpu_error_t gpu_set_input(gpu_context_t *ctx, unsigned char *data);

gpu_error_t gpu_get_output(gpu_context_t *ctx, unsigned char **data);

void gpu_context_free(gpu_context_t *ctx);

#endif