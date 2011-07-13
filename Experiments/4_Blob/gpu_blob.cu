/*
	(15,16) ---> 15*16 = 240 
	(16,20) ---> 16*20 = 320
	
	each block will be of dimension 15 x 16.

	(20,20)

	In the shared memory the labelSharedMemory contains the index value of the pixel as root. Labelling is done by storing value of indices at the pixels.
	The index value stored is the one that is minimum from its neighbouring 8 pixels.
							
	-------------------------------------------------------------------------
	|							Shared Memory								|
	|	-------------------------		-----------------------------		|
	|	|						|		|							|		|
	|	|						|		|							|		|
	|	|		Label			|		|		  Segment 			|		|
	|	|	Shared Memory		|		|	   Shared Memory    	|		|
	|	|						|		|							|		|
	|	|						|		|							|		|
	|	|						|		|							|		|
	|	-------------------------		-----------------------------		|
	-------------------------------------------------------------------------
*/

/*
	The best way to do labelling is using disjoint set datasctructure(Union Find DS).
	See Wikipidea
*/

#include "cuda.h"
#include "cuda_runtime.h"
#include "stdio.h"

inline __device__ int findRoot(int* buf, int x) 
{
	int nextX;
    do {
	  nextX = x;
      x = buf[nextX];
    } while (x < nextX);
    return x;    
}

inline
__device__ void unionF(int* buf, unsigned char *buf_uchar, unsigned char seg1, unsigned char seg2, int reg1, int reg2, int* changed)
{
	if(seg1 == seg2) {			
		int newReg1 = findRoot(buf, reg1);		
		int newReg2 = findRoot(buf, reg2);	
	
		if(newReg1 > newReg2) {			
			atomicMin(buf+newReg1, newReg2);		
			buf_uchar[newReg1] = min( buf_uchar[newReg1], newReg2);		
			changed[0] = 1;			
		} else if(newReg2 > newReg1) {		
			atomicMin(buf+newReg2, newReg1);	
			buf_uchar[newReg2] = min( buf_uchar[newReg2], newReg2);
			changed[0] = 1;
		}			
	} 	
}

/*
__shared__ __device__ bool atmFlag = false;
inline __device__ int gpuMin( int *temp, int newLabel)
{
	*temp = min( *temp, newLabel);

}
*/

texture<unsigned char, 2, cudaReadModeElementType> texSrc;


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/*													  Local labelling of Blobs 															   */
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

__global__ void cclSharedLabelling( unsigned char *gpu_in, int *gpu_labels, unsigned char *gpu_labels_uchar, const int pitch, const int segOff, const int dataWidth)
{
	int 	  x = blockIdx.x * blockDim.x + threadIdx.x;
    int       y = blockIdx.y * blockDim.y + threadIdx.y;
    int  offset = x + y * blockDim.x * gridDim.x;
    int shPitch = blockDim.x + 2;	// This is the pitch for shared memory of labels.

    int    localIndex = threadIdx.x + 1 + (threadIdx.y + 1) * shPitch; // This is the local address inside shared memory that has 1 pixel width of apron.
    int      newLabel = localIndex;
    int      oldLabel = 0;
    int         index = x + y * pitch; // This is the address of the pixel in global memory
    int segLocalIndex = localIndex + segOff;

	// This is the new syntax for declaring shared memory //
    extern __shared__ int sMem[];

    //shared flag that is used to check for the final solution on the processed tile 
	//if there are any two connected elements with different labels the flag is set to 1
	__shared__ int sChanged[1];

	////// Initializing the shared memory. Setting the boundary values to 0 i.e background /////
	if(threadIdx.x == blockDim.x-1) 
	{	
		sMem[localIndex+1] = 0;
		sMem[segLocalIndex+1] = 0;
	}
	if(threadIdx.x == 0) 
	{	
		sMem[localIndex-1] = 0;
		sMem[segLocalIndex-1] = 0;
	}
	if(threadIdx.y == blockDim.y-1) {			
		sMem[localIndex+shPitch] = 0;
		sMem[segLocalIndex+shPitch] = 0;

		if(threadIdx.x == 0) {			
			sMem[localIndex+shPitch-1] = 0;
			sMem[segLocalIndex+shPitch-1] = 0;
		}
		if(threadIdx.x == blockDim.x-1) {			
			sMem[localIndex+shPitch+1] = 0;
			sMem[segLocalIndex+shPitch+1] = 0;
		}	
	}
	if(threadIdx.y == 0) {			
		sMem[localIndex-shPitch] = 0;
		sMem[segLocalIndex-shPitch] = 0;
		if(threadIdx.x == 0) {			
			sMem[localIndex-shPitch-1] = 0;
			sMem[segLocalIndex-shPitch-1] = 0;
		}
		if(threadIdx.x == blockDim.x-1) {			
			sMem[localIndex-shPitch+1] = 0;
			sMem[segLocalIndex-shPitch+1] = 0;
		}	
	}

	/// VVV IMP: I think that the variables declared inside a __global__ function call are register variables, and not normal variables.
	/// The register variables are faster than shared memory. But dont overuse it due to threads throughput.
	unsigned char pixel;
	unsigned char nPixel[8];	// The neighbouring pixels.

	// Current pixel retrieved for processing //
	//pixel = tex2D( texSrc, x, y);  // This is with usage of textures.
	pixel = gpu_in[ offset ];	// This is with global memory call.
	
	sMem[segLocalIndex] = (int)pixel;// This step will load the segmentation shared memory with all the required pixels
	__syncthreads();

	//store data about segments into registers so that we don't have to access shared memory
	//(the data are never modified)
	nPixel[0] = sMem[segLocalIndex-shPitch-1];
	nPixel[1] = sMem[segLocalIndex-shPitch];
	nPixel[2] = sMem[segLocalIndex-shPitch+1];
	nPixel[3] = sMem[segLocalIndex-1];
	nPixel[4] = sMem[segLocalIndex+1];
	nPixel[5] = sMem[segLocalIndex+shPitch-1];
	nPixel[6] = sMem[segLocalIndex+shPitch];
	nPixel[7] = sMem[segLocalIndex+shPitch+1];

	while(!NULL)
	{
		//in first pass the newLabel is equal to the local address of the element
		sMem[localIndex] = newLabel;

		//reset the check flag for each block
		if((threadIdx.x | threadIdx.y) == 0) sChanged[0] = 0;
		oldLabel = newLabel;
		__syncthreads();

		//if the element is not a background, compare the element's label with its neighbors
		if(pixel != 0) 
		{	
			if( pixel == nPixel[0])
				newLabel = min( newLabel, sMem[localIndex-shPitch-1]);
			if( pixel == nPixel[1])
				newLabel = min( newLabel, sMem[localIndex-shPitch]);
			if( pixel == nPixel[2])
				newLabel = min( newLabel, sMem[localIndex-shPitch+1]);
			if( pixel == nPixel[3])
				newLabel = min( newLabel, sMem[localIndex-1]);
			if( pixel == nPixel[4])
				newLabel = min( newLabel, sMem[localIndex+1]);
			if( pixel == nPixel[5])
				newLabel = min( newLabel, sMem[localIndex+shPitch-1]);
			if( pixel == nPixel[6])
				newLabel = min( newLabel, sMem[localIndex+shPitch]);
			if( pixel == nPixel[7])
				newLabel = min( newLabel, sMem[localIndex+shPitch+1]);
				
		}
		__syncthreads();

		if( oldLabel > newLabel)
		{
			//if there is a neigboring element with a smaller label, update the equivalence tree of the processed element
			//(the tree is always flattened in this stage so there is no need to use findRoot to find the root)
	
			// VVVVIMP: This step is like merging of two trees together.
				
            //Be carefull when removing this function. Atomic is used to prevent multiple threads from accessing same memory.
			//It is like a particualar thread has acquired a lock on the address.
			
			
			atomicMin(sMem+oldLabel, newLabel); 
			//sMem[localIndex] = newLabel;
			//sMem[oldLabel] = min( sMem[oldLabel], newLabel);

			
			//set the flag to 1 bcoz it is necessary to perform another iteration of the CCL solver
			sChanged[0] = 1;
		}
		__syncthreads();

		if(sChanged[0] == 0) break;

		//flatten the equivalence tree
		newLabel = findRoot(sMem,newLabel);			
		__syncthreads();
	
	}	

	if(pixel == 0) newLabel = -1;	 // This is the labelling of the background pixel.
	else
	{	// The following loop translates each local label to a unique global label.
		//transfer the label into global coordinates 
		y = newLabel / (blockDim.x+2);
		x = newLabel - y*(blockDim.x+2);
		x = blockIdx.x*blockDim.x + x-1;
		y = blockIdx.y*blockDim.y + y-1;
		newLabel = x+y*dataWidth;	
	}	

	gpu_labels[index] = newLabel;
	gpu_labels_uchar[index] = (unsigned char)newLabel;

}


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/*													  Merging Blobs at Borders 															   */
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

__global__ void mergeBlobAtBorders( int *gpu_labels, unsigned char *gpu_labels_uchar, const int tileDim, const int pitch)
{
	// These specify the 3 x 4 matrices. Where each matrix element is a combination of 4 x 4 tiles.
	int tileX = threadIdx.x + blockIdx.x * blockDim.x;	
	int tileY = threadIdx.y + blockIdx.y * blockDim.y;

	//the number of times each thread has to be used to process one border of the tile
	int threadIterations = tileDim / blockDim.z;

	//dimensions of the tile on the next level of the merging scheme
	int nextTileDim = tileDim * blockDim.x;

	unsigned char seg;
	int offset;
	
	//shared variable that is set to 1 if an equivalence tree was changed
	__shared__ int sChanged[1];

	while(!NULL)
	{
	
		//reset the check variable
		if(threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0)
		{
			sChanged[0] = 0;			
		}
		__syncthreads();

		//Processing the horizontal border...
		if(threadIdx.y < blockDim.y-1) 
		{
			//the horizontal border corresponds to the last row of the tile (exclude bottom most row)
			uint y = (tileY+1)*tileDim-1;	// Since tileY starts from 0 hence tileY+1
			//offset of the element from the left most boundary of the tile
			offset = threadIdx.x*tileDim + threadIdx.z;
			uint x = tileX * tileDim + threadIdx.z;	// tileDim is same for both x and y directions.
			
			for( int i = 0; i < threadIterations; ++i) 
			{
				seg = tex2D( texSrc, x + 0.5f, y + 0.5f);

				if(seg != 0) 
				{		
					//address of the element in the global space
					int idx = x+y*pitch;
					//perform the union operation on neigboring elements from other tiles that are to be merged with the processed tile
					if(offset>0) unionF( (int *)gpu_labels, gpu_labels_uchar, seg, tex2D( texSrc, x-1+0.5f, y+1+0.5f), idx, idx-1+pitch, sChanged); // Bottom left pixel.
					unionF( (int *)gpu_labels, gpu_labels_uchar, seg, tex2D( texSrc, x+0.5f, y+1+0.5f), idx, idx+pitch, sChanged);				 // Bottom middle pixel.
					if(offset<nextTileDim-1) unionF( (int *)gpu_labels, gpu_labels_uchar, seg, tex2D( texSrc, x+1+0.5f, y+1+0.5f), idx, idx+1+pitch, sChanged);	// Bottom right pixel.
										
				}
				
				//set the processed element to the next in line on the same boundary (in case the threads are used for multiple elements on the boundary)
				x += blockDim.z;
				offset += blockDim.z;	
			}
		}
		//process vertical borders between merged tiles (exclude the right most tiles)
		if( threadIdx.x < blockDim.x - 1)
		{
			//the vertical border corresponds to the right most column of elements in the tile
			uint x = (tileX)*tileDim-1;	
			//offset of the element from the top most boundary of the tile
			offset = threadIdx.y*tileDim + threadIdx.z; 
			uint y = tileY * tileDim + threadIdx.z ;

			for(int i = 0; i < threadIterations; ++i)
			{
				seg = tex2D( texSrc, x+0.5f, y+0.5f);

				if(seg != 0)
				{
					int idx = x+y*pitch;
					//perform the union operation on neigboring elements from other tiles that are to be merged with the processed tile
					if(offset>0) unionF( (int *)gpu_labels, gpu_labels_uchar, seg, tex2D( texSrc, x+1+0.5f, y-1+0.5f), idx, idx+1-pitch, sChanged);
					unionF( (int *)gpu_labels, gpu_labels_uchar, seg, tex2D( texSrc, x+1+0.5f, y+0.5f), idx, idx+1, sChanged);
					if(offset<nextTileDim-1) unionF( (int *)gpu_labels, gpu_labels_uchar,seg, tex2D( texSrc, x+1+0.5f, y+1+0.5f), idx, idx+1+pitch, sChanged);	
				}
				// If no. of threads are insufficient then following code will provide initials.
				y += blockDim.z;
				offset += blockDim.z;	
			}

		}
		__syncthreads();
		//if no equivalence tree was updated then all equivalence trees of the merged tiles are already merged
		if(sChanged[0] == 0) 		
			break;	
		//need to synchronize here because the sChanged variable is changed next
		__syncthreads();		
	}
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/*											     Flattening of Trees after Merging 														   */
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
inline __device__
void flattenEquivalenceTreesInternal(int x, int y, int* gpu_labels_in, int* gpu_labels_out, unsigned char *gpu_labels_uchar, uint pitch, const int dataWidth);

__global__ void flattenTreesAfterMergingKernel( int *gpu_labels_in, int *gpu_labels_out, unsigned char *gpu_labels_uchar, int tileDim, int blocksPerTile)
{
	//multiple thread blocks can be used to update border of a single tile
	int tileX = blockIdx.x / blocksPerTile;
	int tileOffset = blockDim.x*(blockIdx.x & (blocksPerTile-1));
	int tileY = threadIdx.y + (blockIdx.y*blockDim.y);
	int maxTileY = gridDim.y*blockDim.y-1;	
	
	//a single thread is used to update both the horizontal and the verical boundary on both sides of two merged tiles	

	//first process horizontal borders
	if(tileY < maxTileY) {		
		uint y = (tileY+1)*tileDim-1;	
		uint x = tileX*tileDim+threadIdx.x+tileOffset;			
		flattenEquivalenceTreesInternal(x, y, gpu_labels_out, gpu_labels_in, gpu_labels_uchar, 240, 240);
		flattenEquivalenceTreesInternal(x, y+1, gpu_labels_out, gpu_labels_in, gpu_labels_uchar, 240, 240);
	}
	//process vertical borders
	if(tileX < gridDim.x-1) {		
		uint x = (tileX+1)*tileDim-1;		
		uint y = tileY*tileDim+threadIdx.x+tileOffset;
		flattenEquivalenceTreesInternal(x, y, gpu_labels_out, gpu_labels_in, gpu_labels_uchar, 240, 240);
		flattenEquivalenceTreesInternal(x+1, y, gpu_labels_out, gpu_labels_in, gpu_labels_uchar, 240, 240);
						
	}	



}


void flattenTreesAfterMerging( int *gpu_labels_in, int *gpu_labels_out, unsigned char *gpu_labels_char, int threadsX, int threadsY, int imageW, int imageH, int dataWidth, int tileSize)
{
	dim3 block, grid;
	int blocksPerTile;

	//////////////////////////////////////
	int tileX = imageW / tileSize;
	int tileY = imageH / tileSize;
	int maxThreads = threadsX*threadsY;
	if(tileY < threadsY) {
		threadsY = tileY;
		threadsX = maxThreads/threadsY;
	}
	if(threadsX > tileSize) threadsX = tileSize;
	block = dim3(threadsX, threadsY, 1);	
    grid = dim3(imageW / block.x,	(tileY) / block.y, 1);
	blocksPerTile = tileSize / block.x;	
	///////////////////////////////////////

	flattenTreesAfterMergingKernel<<< block, grid>>>( gpu_labels_in, gpu_labels_out, gpu_labels_char, tileSize, blocksPerTile);

}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/*													Flattening of all the elements															*/
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

inline __device__
void flattenEquivalenceTreesInternal(int x, int y, int* gpu_labels_in, int* gpu_labels_out, unsigned char *gpu_labels_uchar, uint pitch, const int dataWidth)
{
	int index = x+y*pitch;	
	int label = gpu_labels_in[index];
	//flatten the tree for all non-background elements whose labels are not roots of the equivalence tree 
	if(label != index && label != -1)
	{
		int newLabel = findRoot( gpu_labels_in, label);			
		if(newLabel < label) 
		{		
			//set the label of the root element as the label of the processed element			
			gpu_labels_out[index] = newLabel;
		}
	}		
}


__global__ void flattenEquivalenceTreesKernel(int* gpu_labels_out, int* gpu_labels_in, unsigned char *gpu_labels_uchar, uint pitch, const int dataWidth)												
{
	uint x = (blockIdx.x*blockDim.x)+threadIdx.x;
    uint y = (blockIdx.y*blockDim.y)+threadIdx.y;  

   	flattenEquivalenceTreesInternal(x, y, gpu_labels_out, gpu_labels_in, gpu_labels_uchar, pitch, dataWidth);

}

/////////////////////////////////////////////////// Main Wrapper about the function //////////////////////////////////////////////////////////
float gpu_DetectBlob( unsigned char *in, unsigned char *labels)
{
	int   imageW = 240;
	int   imageH = 320;
	int threadsX = 20;
	int threadsY = 20;
	float elapsedtime;
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	
    int *gpu_labels;
    cudaMalloc( (void **)&gpu_labels, imageW * imageH * sizeof(int));

    int *labels_int;
    labels_int = (int *)malloc(240*320*sizeof(int));

    //// This buffer is temporary and only used for debuggin purpose ////
    unsigned char *gpu_labels_uchar;
    cudaMalloc( (void **)&gpu_labels_uchar, imageW * imageH * sizeof(unsigned char));
	//////
	
	unsigned char *gpu_in;
	cudaMalloc( (void **)&gpu_in, 240 * 320);
	cudaMemcpy( gpu_in, in, 240 * 320, cudaMemcpyHostToDevice);
    
    cudaEventRecord(start,0);

    //////////////////////////////////////////// Local Shared Labelling /////////////////////////////////////////////////////
    dim3 threads(20,20);
    int tileSize = 20; // It is used in merging phase of borders.
    dim3 blocks(12,16);
  // dim3 threads(40,40);	// Timing was too less with this much threads. FIXME: Try this approach after conversion
  // int tileSize = 40; // It is used in merging phase of borders.
  // dim3 blocks(6,8);
    int labelSize = (threads.x + 2) * (threads.y + 2) * sizeof(int); //This is the size for storage of labels to the corresponding pixels
    int   segSize = (threads.x + 2) * (threads.y + 2) * sizeof(int); //This is the size of storage for segments.
    
	cclSharedLabelling<<< blocks, threads, (labelSize + segSize)>>>( gpu_in, gpu_labels, gpu_labels_uchar, 240, labelSize/sizeof(int), 240);
	/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	
	//////////////////////////////////////////// Merging Blobs Together /////////////////////////////////////////////////////
	
	cudaArray *src;
    cudaChannelFormatDesc floatTex = cudaCreateChannelDesc<unsigned char>();
    cudaMallocArray(&src, &floatTex, imageW, imageH);
    cudaMemcpyToArray(src, 0, 0, gpu_in, imageW * imageH, cudaMemcpyDeviceToDevice);
    cudaBindTextureToArray(texSrc, src);
   // The reason for using texture memopory is that no coalascing can occur in global memory for memory access on borders

    while(tileSize < imageW || tileSize < imageH)
    {
    	//computing the number of tiles that are going to be merged in a singe thread block
    	int xTiles = 4;
		int yTiles = 4;
		if(xTiles*tileSize > imageW) xTiles = imageW / tileSize;	// These are the fallback assignments when the tiles will be merged incremently.
		if(yTiles*tileSize > imageH) yTiles = imageH / tileSize;

		int threadsPerBlock = 40;	// FIXME: This value will cause problems.
		if(tileSize < threadsPerBlock) threadsPerBlock = tileSize;
		// In the first iteration value of threadsPerBlock is 20.

		dim3 block(xTiles,yTiles,threadsPerBlock);
		dim3 grid(imageW/(block.x*tileSize), imageH/(block.x*tileSize), 1);

		mergeBlobAtBorders<<< grid, block>>>( gpu_labels, gpu_labels_uchar, tileSize, 240 );

		if(yTiles > xTiles) tileSize = yTiles * tileSize;
		else tileSize = xTiles * tileSize;

		
		if(tileSize < imageW || tileSize < imageH)
		{
			//update borders
			flattenTreesAfterMerging( gpu_labels, gpu_labels, gpu_labels_uchar, threadsX, threadsY, imageW, imageH, 240 * sizeof(int), tileSize);
		}
		
    }
    cudaUnbindTexture(texSrc);
	//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


	//////////////////////////////////////// Updating all the labels (i.e flattening )/////////////////////////////////////////////////
	/*
	dim3 block(threadsX, threadsY, 1);
    dim3 grid(imageW / block.x, imageH / block.y, 1);

    flattenEquivalenceTreesKernel<<<grid, block>>>( gpu_labels, gpu_labels, gpu_labels_uchar, 240, 240);
	*/
	
	//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	cudaEventRecord(stop,0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedtime,start,stop);
	cudaEventDestroy(start);
	cudaEventDestroy(stop);

	//cudaMemcpy( in, gpu_labels, 240*320, cudaMemcpyDeviceToHost);

	cudaMemcpy( labels, gpu_labels_uchar, 240*320, cudaMemcpyDeviceToHost);
	cudaMemcpy( labels_int, gpu_labels, 240*320*sizeof(int), cudaMemcpyDeviceToHost);
	cudaFree(gpu_labels);
	cudaFree(gpu_labels_uchar);
    
    FILE *file;
	file = fopen("debug.txt","a+"); // apend file (add text to a file or create a file if it does not exist.
	for(int i=0;i<240*320;i++)
	{
		if((i>239) && (i%240==0))
			fprintf(file,"\n");
		fprintf(file,"%d ", labels_int[i]); 
	}
	fprintf(file,"\n");
	fclose(file); //done!

    return elapsedtime;

}
