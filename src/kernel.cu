#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too. (particleArrays and gridCellIndices)

// For efficient sorting and the uniform grid. These should always be parallel.

int *dev_particleArrayIndices; // - buffer containing a pointer for each boid to
                               //   its data in dev_pos and dev_vel1 and dev_vel2
int *dev_particleGridIndices;  // - buffer containing the grid index of each boid

// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // - buffer containing a pointer for each cell to
                               //   the beginning of its data in dev_particleArrayIndices
int *dev_gridCellEndIndices;   // - buffer containing a pointer for each cell to
                               //   the end of its data in dev_particleArrayIndices

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
// HB - same as its corresponding pos,vel1,vel2 buffers except sorted to match
// the current grid cell index locations
glm::vec3* dev_shuffledPos;
glm::vec3* dev_shuffledVel1;   

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount; //gridResolution
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  dev_thrust_particleArrayIndices = thrust::device_pointer_cast<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices = thrust::device_pointer_cast<int>(dev_particleGridIndices);

  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  // TODO-2.3 Allocate additional buffers here.
  cudaMalloc((void**)&dev_shuffledPos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_shuffledPos failed!");

  cudaMalloc((void**)&dev_shuffledVel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_shuffledVel1Indices failed!");

  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* TODO-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
  glm::vec3 perceived_center_rule1(0.f);
  glm::vec3 iSelf_position = pos[iSelf];

  glm::vec3 adhesion_velocity_rule1(0.f);
  glm::vec3 dodging_velocity_rule2(0.f);
  glm::vec3 cohesion_velocity_rule3(0.f);

  float neighbors_rule1 = 0.f;
  float neighbors_rule3 = 0.f;

  for (int on_index = 0; on_index < N; ++on_index) {
    if (on_index == iSelf) { continue; }
    glm::vec3 on_pos = pos[on_index];
    float distance = glm::distance(iSelf_position, on_pos);
    // Rule 1: Boids try to fly towards the center of mass of neighboring boids
    if (distance < rule1Distance) {
      perceived_center_rule1 += on_pos;
      ++neighbors_rule1;
    }
    // Rule 2: Boids try to keep a small distance away from other objects (including other boids).
    if (distance < rule2Distance) {
      dodging_velocity_rule2 += (iSelf_position - on_pos);
    }
    // Rule 3: Boids try to match velocity with near boids.
    if (distance < rule3Distance) {
      cohesion_velocity_rule3 += vel[on_index];
      ++neighbors_rule3;
    }
  }

  // final updates before summing
  adhesion_velocity_rule1 = (neighbors_rule1 > 0) ? (perceived_center_rule1 / neighbors_rule1 - iSelf_position) * rule1Scale : glm::vec3(0.f);
  dodging_velocity_rule2 *= rule2Scale;
  cohesion_velocity_rule3 = (neighbors_rule3 > 0) ? cohesion_velocity_rule3 / neighbors_rule3 * rule3Scale : glm::vec3(0.f);

  return adhesion_velocity_rule1 + dodging_velocity_rule2 + cohesion_velocity_rule3;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its velocity based on its current position.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisVelo = vel1[index] + computeVelocityChange(N, index, pos, vel1);
  // clamp speed and reupdate
  vel2[index] = glm::length(thisVelo) > maxSpeed ? glm::normalize(thisVelo) * maxSpeed : thisVelo;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }

  // TODO-2.1
  // - Label each boid with the index of its grid cell. HB zero out origin of grid
  glm::ivec3 cell_index_3D = glm::floor((pos[index] - gridMin) * inverseCellWidth);
  gridIndices[index] = gridIndex3Dto1D(
    cell_index_3D.x, cell_index_3D.y, cell_index_3D.z, gridResolution);

  // Set up a parallel array of integer indices as pointers to the actual
  // boid data in pos and vel1/vel2 - HB fill in the array dev_particleArrayIndices
  // for what each indices[index] points to which gridIndices[index] value
  // since initializing - in same order.
  indices[index] = index;
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  // HB - indexing is only first inclusive [start, end).

  int particle_index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (particle_index >= N) {
    return;
  }
  int current_grid_index = particleGridIndices[particle_index];

  // starting edge case
  if (particle_index == 0) {
    gridCellStartIndices[current_grid_index] = particle_index;
    return;
  }
  // general case
  int previous_grid_index = particleGridIndices[particle_index - 1];
  if (current_grid_index != previous_grid_index) {
    gridCellStartIndices[current_grid_index] = particle_index;
    gridCellEndIndices[previous_grid_index] = particle_index;
  }
  // ending edge case
  if (particle_index == N - 1) {
    gridCellEndIndices[current_grid_index] = particle_index + 1;
  }
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {

  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  int particle_index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (particle_index >= N) {
    return;
  }
  glm::vec3 particle_position = pos[particle_index];
  glm::ivec3 current_cell_index_3D = (particle_position - gridMin) * inverseCellWidth;

  // Identify which cells may contain neighbors.
  float max_distance_val = glm::max(rule1Distance, glm::max(rule2Distance, rule3Distance));
  glm::vec3 max_distance(max_distance_val);
  glm::vec3 zeroed_particle_position = particle_position - gridMin;
  glm::vec3 min_cell_index_3D = (zeroed_particle_position - max_distance) * inverseCellWidth;
  glm::vec3 max_cell_index_3D = (zeroed_particle_position + max_distance) * inverseCellWidth;

  // clamp 3D cell index bounds (not wrapping here)
  glm::vec3 grid_min_index(0);
  glm::vec3 grid_max_index(gridResolution);

  glm::ivec3 grid_min_3D = glm::clamp(min_cell_index_3D, grid_min_index, grid_max_index);
  glm::ivec3 grid_max_3D = glm::clamp(max_cell_index_3D, grid_min_index, grid_max_index);

  // Update particle velocity based on neighboring boids
  glm::vec3 perceived_center_rule1(0.f);

  glm::vec3 adhesion_velocity_rule1(0.f);
  glm::vec3 dodging_velocity_rule2(0.f);
  glm::vec3 cohesion_velocity_rule3(0.f);

  float neighbors_rule1 = 0.f;
  float neighbors_rule3 = 0.f;

  for (int z = grid_min_3D.z; z <= grid_max_3D.z; ++z) {
    for (int y = grid_min_3D.y; y <= grid_max_3D.y; ++y) {
      for (int x = grid_min_3D.x; x <= grid_max_3D.x; ++x) {
        int checking_cell_index_1D = gridIndex3Dto1D(x, y, z, gridResolution);

        int start_boid_index = gridCellStartIndices[checking_cell_index_1D];
        int end_boid_index = gridCellEndIndices[checking_cell_index_1D];

        if (start_boid_index < 0 || start_boid_index >= N || end_boid_index < 0 || end_boid_index >= N) {
          continue;
        }

        for (int b = start_boid_index; b < end_boid_index; ++b) {
          int on_boid = particleArrayIndices[b];
          if (on_boid == particle_index) { continue; }

          glm::vec3 boid_position = pos[on_boid];
          float distance = glm::distance(particle_position, boid_position);
          // Rule 1: Boids try to fly towards the center of mass of neighboring boids
          if (distance < rule1Distance) {
            perceived_center_rule1 += boid_position;
            ++neighbors_rule1;
          }
          // Rule 2: Boids try to keep a small distance away from other objects (including other boids).
          if (distance < rule2Distance) {
            dodging_velocity_rule2 += (particle_position - boid_position);
          }
          // Rule 3: Boids try to match velocity with near boids.
          if (distance < rule3Distance) {
            cohesion_velocity_rule3 += vel1[on_boid];
            ++neighbors_rule3;
          }
        } // end: iterating over all boids in a cell
      }
    }
  }

  // final updates before summing
  adhesion_velocity_rule1 = (neighbors_rule1 > 0)
    ? (perceived_center_rule1 / neighbors_rule1 - particle_position) * rule1Scale
    : glm::vec3(0.f);
  dodging_velocity_rule2 *= rule2Scale;
  cohesion_velocity_rule3 = (neighbors_rule3 > 0)
    ? cohesion_velocity_rule3 / neighbors_rule3 * rule3Scale
    : glm::vec3(0.f);

  // clamp and update
  glm::vec3 updated_velocity = vel1[particle_index]
    + adhesion_velocity_rule1 + dodging_velocity_rule2 + cohesion_velocity_rule3;
  vel2[particle_index] = (glm::length(updated_velocity) > maxSpeed)
    ? glm::normalize(updated_velocity) * maxSpeed
    : updated_velocity;
}

__global__ void kernShuffleBuffer(int N, int *particleArrayIndices, glm::vec3* original_ordering, glm::vec3* shuffled_ordering) {
  int particle_index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (particle_index >= N) {
    return;
  }

  // swapping v1 and v2 while also sorting appropriately
  shuffled_ordering[particle_index] = original_ordering[particleArrayIndices[particle_index]];
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.

  int particle_index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (particle_index >= N) {
    return;
  }
  glm::vec3 particle_position = pos[particle_index];
  glm::ivec3 current_cell_index_3D = (particle_position - gridMin) * inverseCellWidth;

  // Identify which cells may contain neighbors.
  float max_distance_val = glm::max(rule1Distance, glm::max(rule2Distance, rule3Distance));
  glm::vec3 max_distance(max_distance_val);
  glm::vec3 zeroed_particle_position = particle_position - gridMin;
  glm::vec3 min_cell_index_3D = (zeroed_particle_position - max_distance) * inverseCellWidth;
  glm::vec3 max_cell_index_3D = (zeroed_particle_position + max_distance) * inverseCellWidth;

  // clamp 3D cell index bounds (not wrapping here)
  glm::vec3 grid_min_index(0);
  glm::vec3 grid_max_index(gridResolution);

  glm::ivec3 grid_min_3D = glm::clamp(min_cell_index_3D, grid_min_index, grid_max_index);
  glm::ivec3 grid_max_3D = glm::clamp(max_cell_index_3D, grid_min_index, grid_max_index);

  // Update particle velocity based on neighboring boids
  glm::vec3 perceived_center_rule1(0.f);

  glm::vec3 adhesion_velocity_rule1(0.f);
  glm::vec3 dodging_velocity_rule2(0.f);
  glm::vec3 cohesion_velocity_rule3(0.f);

  float neighbors_rule1 = 0.f;
  float neighbors_rule3 = 0.f;

  for (int z = grid_min_3D.z; z <= grid_max_3D.z; ++z) {
    for (int y = grid_min_3D.y; y <= grid_max_3D.y; ++y) {
      for (int x = grid_min_3D.x; x <= grid_max_3D.x; ++x) {
        int checking_cell_index_1D = gridIndex3Dto1D(x, y, z, gridResolution);

        int start_boid_index = gridCellStartIndices[checking_cell_index_1D];
        int end_boid_index = gridCellEndIndices[checking_cell_index_1D];

        if (start_boid_index < 0 || start_boid_index >= N || end_boid_index < 0 || end_boid_index >= N) {
          continue;
        }

        for (int b = start_boid_index; b < end_boid_index; ++b) {
          if (b == particle_index) { continue; }

          glm::vec3 boid_position = pos[b];
          float distance = glm::distance(particle_position, boid_position);
          // Rule 1: Boids try to fly towards the center of mass of neighboring boids
          if (distance < rule1Distance) {
            perceived_center_rule1 += boid_position;
            ++neighbors_rule1;
          }
          // Rule 2: Boids try to keep a small distance away from other objects (including other boids).
          if (distance < rule2Distance) {
            dodging_velocity_rule2 += (particle_position - boid_position);
          }
          // Rule 3: Boids try to match velocity with near boids.
          if (distance < rule3Distance) {
            cohesion_velocity_rule3 += vel1[b];
            ++neighbors_rule3;
          }
        } // end: iterating over all boids in a cell
      }
    }
  }

  // final updates before summing
  adhesion_velocity_rule1 = (neighbors_rule1 > 0)
    ? (perceived_center_rule1 / neighbors_rule1 - particle_position) * rule1Scale
    : glm::vec3(0.f);
  dodging_velocity_rule2 *= rule2Scale;
  cohesion_velocity_rule3 = (neighbors_rule3 > 0)
    ? cohesion_velocity_rule3 / neighbors_rule3 * rule3Scale
    : glm::vec3(0.f);

  // clamp and update
  glm::vec3 updated_velocity = vel1[particle_index]
    + adhesion_velocity_rule1 + dodging_velocity_rule2 + cohesion_velocity_rule3;
  vel2[particle_index] = (glm::length(updated_velocity) > maxSpeed)
    ? glm::normalize(updated_velocity) * maxSpeed
    : updated_velocity;
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  dim3 blocksPerGrid((numObjects + blockSize - 1) / blockSize);
  // Use the kernels to step the simulation forward in time.
  kernUpdateVelocityBruteForce<<<blocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");
  kernUpdatePos<<<blocksPerGrid, threadsPerBlock>>>(numObjects, dt, dev_pos, dev_vel1);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // Ping-pong/swap the velocity buffers, so now have calculated updated velocity as current
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

void Boids::stepSimulationScatteredGrid(float dt) {
  dim3 blocksPerGrid((numObjects + blockSize - 1) / blockSize);

  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  kernComputeIndices<<<blocksPerGrid, threadsPerBlock >>>(
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
    dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  thrust::sort_by_key(dev_thrust_particleGridIndices,
                      dev_thrust_particleGridIndices + numObjects,
                      dev_thrust_particleArrayIndices);

  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  kernResetIntBuffer<<<blocksPerGrid, threadsPerBlock >>>(numObjects, dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");
  kernResetIntBuffer<<<blocksPerGrid, threadsPerBlock >>>(numObjects, dev_gridCellEndIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");

  kernIdentifyCellStartEnd<<<blocksPerGrid, threadsPerBlock>>>(
    numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

  // - Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchScattered<<<blocksPerGrid, threadsPerBlock>>>(
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth,
    dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices,
    dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

  // - Update positions
  kernUpdatePos<<<blocksPerGrid, threadsPerBlock>>>(numObjects, dt, dev_pos, dev_vel1);
  checkCUDAErrorWithLine("kernUpdatePos brute force failed!");

  // - Ping-pong buffers as needed
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

void Boids::stepSimulationCoherentGrid(float dt) {
  dim3 blocksPerGrid((numObjects + blockSize - 1) / blockSize);

  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  kernComputeIndices<<<blocksPerGrid, threadsPerBlock>>>(
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
    dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  thrust::sort_by_key(dev_thrust_particleGridIndices,
    dev_thrust_particleGridIndices + numObjects,
    dev_thrust_particleArrayIndices);

  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  kernResetIntBuffer<<<blocksPerGrid, blockSize>>>(numObjects, dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<blocksPerGrid, blockSize>>>(numObjects, dev_gridCellEndIndices, -1);

  kernIdentifyCellStartEnd<<<blocksPerGrid, blockSize>>>(numObjects, dev_particleGridIndices,
    dev_gridCellStartIndices, dev_gridCellEndIndices);
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // HB need separate buffers bc cant write to same location as other threads
  kernShuffleBuffer<<<blocksPerGrid, threadsPerBlock>>>(numObjects, dev_particleArrayIndices, dev_pos, dev_shuffledPos);
  kernShuffleBuffer<<<blocksPerGrid, threadsPerBlock>>>(numObjects, dev_particleArrayIndices, dev_vel1, dev_shuffledVel1);

  // HB put ordering back in appropriate buffers
  cudaDeviceSynchronize();
  cudaMemcpy(dev_pos, dev_shuffledPos, numObjects * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);
  cudaMemcpy(dev_vel1, dev_shuffledVel1, numObjects * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);

  // - Perform velocity updates using neighbor search
  kernUpdateVelNeighborSearchCoherent<<<blocksPerGrid, threadsPerBlock>>>(
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth,
    dev_gridCellStartIndices, dev_gridCellEndIndices,
    dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

  // - Update positions
  kernUpdatePos<<<blocksPerGrid, threadsPerBlock>>>(numObjects, dt, dev_pos, dev_vel1);
  checkCUDAErrorWithLine("kernUpdatePos brute force failed!");

  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 - Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  
  // TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_shuffledPos);
  cudaFree(dev_shuffledVel1);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
