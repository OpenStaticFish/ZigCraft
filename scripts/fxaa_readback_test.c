// CPU Vulkan device only. See test_shader_optimizations.py for the GLSL adapter.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#define VK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { fprintf(stderr, "%s: %d\n", #call, r); exit(2); } } while (0)
static VkDevice device;
static VkPhysicalDevice physical;
static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags flags) {
    VkPhysicalDeviceMemoryProperties p; vkGetPhysicalDeviceMemoryProperties(physical, &p);
    for (uint32_t i = 0; i < p.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & flags) == flags) return i;
    abort();
}
typedef struct { VkBuffer handle; VkDeviceMemory memory; void *data; } Buffer;
static Buffer buffer(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buffer b = {0};
    VkBufferCreateInfo ci = {.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size=size, .usage=usage};
    VK(vkCreateBuffer(device, &ci, NULL, &b.handle));
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, b.handle, &req);
    VkMemoryAllocateInfo ai = {.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize=req.size,
        .memoryTypeIndex=memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
    VK(vkAllocateMemory(device, &ai, NULL, &b.memory)); VK(vkBindBufferMemory(device,b.handle,b.memory,0));
    VK(vkMapMemory(device,b.memory,0,size,0,&b.data)); return b;
}
static VkShaderModule shader(const char *path) {
    FILE *f = fopen(path,"rb"); if (!f) abort(); fseek(f,0,SEEK_END); long n=ftell(f); rewind(f);
    uint32_t *code=malloc(n); if (fread(code,1,n,f)!=(size_t)n) abort(); fclose(f);
    VkShaderModuleCreateInfo ci={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=n,.pCode=code};
    VkShaderModule s; VK(vkCreateShaderModule(device,&ci,NULL,&s)); free(code); return s;
}
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    uint32_t w=atoi(argv[3]), h=atoi(argv[4]); size_t count=(size_t)w*h;
    if (!w || !h || w > 4096 || h > 4096) return 2;
    VkInstance instance;
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="FXAA equivalence readback",.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
    VK(vkCreateInstance(&ici,NULL,&instance));
    uint32_t n=1; VK(vkEnumeratePhysicalDevices(instance,&n,&physical));
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(physical,&props);
    if (props.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) { fprintf(stderr,"Refusing non-CPU device\n"); return 2; }
    fprintf(stderr,"readback device: %s\n",props.deviceName);
    uint32_t families=0; vkGetPhysicalDeviceQueueFamilyProperties(physical,&families,NULL);
    VkQueueFamilyProperties *qp=calloc(families,sizeof(*qp)); vkGetPhysicalDeviceQueueFamilyProperties(physical,&families,qp);
    uint32_t family=0; while (family<families && !(qp[family].queueFlags & VK_QUEUE_COMPUTE_BIT)) family++; free(qp);
    float priority=1;
    VkDeviceQueueCreateInfo qci={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci};
    VK(vkCreateDevice(physical,&dci,NULL,&device)); VkQueue queue; vkGetDeviceQueue(device,family,0,&queue);
    Buffer input=buffer(count*4,VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    Buffer output[2]={buffer(count*16,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT),buffer(count*16,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)};
    uint8_t *pixels=input.data; uint32_t random=12345;
    for (uint32_t y=0;y<h;y++) for (uint32_t x=0;x<w;x++) {
        size_t i=((size_t)y*w+x)*4; random=random*1664525u+1013904223u;
        for (uint32_t c=0;c<3;c++) {
            // Flat regions, single-pixel checkerboard, slanted edges, gradients, noise.
            uint32_t region=(x*5)/w;
            pixels[i+c]=region==0 ? 85 : region==1 ? ((x+y)%2)*255 : region==2 ? ((x+y/3)%31<15)*255 : region==3 ? (x+y+c*31)%256 : (random>>(c*8))&255;
        }
        pixels[i+3]=255;
    }
    VkImage image; VkDeviceMemory imemory;
    VkImageCreateInfo image_ci={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,.format=strcmp(argv[5],"srgb")==0 ? VK_FORMAT_R8G8B8A8_SRGB : VK_FORMAT_R8G8B8A8_UNORM,
        .extent={w,h,1},.mipLevels=1,.arrayLayers=1,.samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,
        .usage=VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT};
    VK(vkCreateImage(device,&image_ci,NULL,&image)); VkMemoryRequirements req; vkGetImageMemoryRequirements(device,image,&req);
    VkMemoryAllocateInfo mai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=memory_type(req.memoryTypeBits,0)};
    VK(vkAllocateMemory(device,&mai,NULL,&imemory)); VK(vkBindImageMemory(device,image,imemory,0));
    VkImageView view; VkImageViewCreateInfo vci={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=image,.viewType=VK_IMAGE_VIEW_TYPE_2D,
        .format=image_ci.format,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    VK(vkCreateImageView(device,&vci,NULL,&view));
    VkSampler sampler; VkSamplerCreateInfo sci={.sType=VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,.magFilter=VK_FILTER_LINEAR,.minFilter=VK_FILTER_LINEAR,
        .addressModeU=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.addressModeV=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE};
    VK(vkCreateSampler(device,&sci,NULL,&sampler));
    VkDescriptorSetLayoutBinding bindings[2]={{.binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT},
        {.binding=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT}};
    VkDescriptorSetLayout layout; VkDescriptorSetLayoutCreateInfo lci={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=2,.pBindings=bindings};
    VK(vkCreateDescriptorSetLayout(device,&lci,NULL,&layout));
    VkDescriptorPoolSize sizes[2]={{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,2},{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2}};
    VkDescriptorPool pool; VkDescriptorPoolCreateInfo pci={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=2,.poolSizeCount=2,.pPoolSizes=sizes};
    VK(vkCreateDescriptorPool(device,&pci,NULL,&pool));
    VkDescriptorSetLayout layouts[2]={layout,layout}; VkDescriptorSet sets[2];
    VkDescriptorSetAllocateInfo dai={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=pool,.descriptorSetCount=2,.pSetLayouts=layouts};
    VK(vkAllocateDescriptorSets(device,&dai,sets));
    for (int i=0;i<2;i++) {
        VkDescriptorImageInfo ii={sampler,view,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}; VkDescriptorBufferInfo bi={output[i].handle,0,count*16};
        VkWriteDescriptorSet writes[2]={{.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=sets[i],.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.pImageInfo=&ii},
            {.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=sets[i],.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&bi}};
        vkUpdateDescriptorSets(device,2,writes,0,NULL);
    }
    VkPushConstantRange push={VK_SHADER_STAGE_COMPUTE_BIT,0,16};
    VkPipelineLayout pl; VkPipelineLayoutCreateInfo plci={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&layout,.pushConstantRangeCount=1,.pPushConstantRanges=&push};
    VK(vkCreatePipelineLayout(device,&plci,NULL,&pl)); VkPipeline pipelines[2]; VkShaderModule modules[2];
    for (int i=0;i<2;i++) {
        modules[i]=shader(argv[i+1]);
        VkComputePipelineCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.layout=pl,
            .stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=modules[i],.pName="main"}};
        VK(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&cpi,NULL,&pipelines[i]));
    }
    VkCommandPool cp; VkCommandPoolCreateInfo cpci={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=family};
    VK(vkCreateCommandPool(device,&cpci,NULL,&cp)); VkCommandBuffer cmd;
    VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cp,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
    VK(vkAllocateCommandBuffers(device,&cai,&cmd)); VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(cmd,&begin));
    VkImageMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
        .oldLayout=VK_IMAGE_LAYOUT_UNDEFINED,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.image=image,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&barrier);
    VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={w,h,1}};
    vkCmdCopyBufferToImage(cmd,input.handle,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
    barrier.oldLayout=barrier.newLayout; barrier.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,0,NULL,0,NULL,1,&barrier);
    float params[4]={1.0f/w,1.0f/h,8.0f,1.0f/8};
    for (int i=0;i<2;i++) {
        vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipelines[i]); vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,1,&sets[i],0,NULL);
        vkCmdPushConstants(cmd,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,16,params); vkCmdDispatch(cmd,(w+7)/8,(h+7)/8,1);
    }
    VkMemoryBarrier host={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,.dstAccessMask=VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&host,0,NULL,0,NULL);
    VK(vkEndCommandBuffer(cmd)); VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};
    VK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)); VK(vkQueueWaitIdle(queue));
    float *a=output[0].data,*b=output[1].data; double total=0; float max=0; size_t changed=0, quantized=0; int max_byte=0;
    for (size_t i=0;i<count*4;i++) {
        if (!isfinite(a[i]) || !isfinite(b[i])) abort();
        float d=fabsf(a[i]-b[i]); if(d>max)max=d; total+=d; changed+=(d!=0);
        int diff=abs((int)lrintf(a[i]*255)-(int)lrintf(b[i]*255)); quantized+=(diff!=0); if(diff>max_byte)max_byte=diff;
    }
    printf("%ux%u %s: float differing channels=%zu max=%g mean=%g; UNORM8 differing channels=%zu max=%d\n",w,h,argv[5],changed,max,total/(count*4),quantized,max_byte);
    vkDestroyCommandPool(device,cp,NULL);
    for(int i=0;i<2;i++){vkDestroyPipeline(device,pipelines[i],NULL);vkDestroyShaderModule(device,modules[i],NULL);}
    vkDestroyPipelineLayout(device,pl,NULL);vkDestroyDescriptorPool(device,pool,NULL);vkDestroyDescriptorSetLayout(device,layout,NULL);
    vkDestroySampler(device,sampler,NULL);vkDestroyImageView(device,view,NULL);vkDestroyImage(device,image,NULL);vkFreeMemory(device,imemory,NULL);
    Buffer all[3]={input,output[0],output[1]};for(int i=0;i<3;i++){vkUnmapMemory(device,all[i].memory);vkDestroyBuffer(device,all[i].handle,NULL);vkFreeMemory(device,all[i].memory,NULL);}
    vkDestroyDevice(device,NULL);vkDestroyInstance(instance,NULL);
    return changed != 0 ? 1 : 0;
}
