#include "CudaImage.h"
#include "cudaUtil.h"
using G3D::GLPixelTransferBuffer;

CudaImage::CudaImage(int width, int height, const G3D::ImageFormat* imageFormat, const void* data) : m_width(width), m_height(height), m_format(imageFormat), m_data(NULL) {
    alwaysAssertM(m_format == G3D::ImageFormat::R32F() || m_format == G3D::ImageFormat::RGBA32F() || m_format == G3D::ImageFormat::RGBA8() || m_format == G3D::ImageFormat::BGRA8(), "CudaImage only supports 1 and 4 channel float formats and 4 channel 8-bit formats for now");
    size_t allocationSize = sizeInMemory();
    CUDA_SAFE_CALL(cudaMalloc(&m_data, allocationSize));
    if (data != NULL) {
        updateFromMemory(data);
    } else {
        CUDA_SAFE_CALL(cudaMemset(m_data, 0, allocationSize));
    }

}

void CudaImage::updateFromMemory(const void* newData) {
    CUDA_SAFE_CALL(cudaMemcpy(m_data, newData, sizeInMemory(), cudaMemcpyHostToDevice));
}

void CudaImage::copyTo(void* dst) {
    CUDA_SAFE_CALL(cudaMemcpy(dst, m_data, sizeInMemory(), cudaMemcpyDeviceToHost));
}

shared_ptr<CudaImage> CudaImage::createEmpty(int width, int height, const G3D::ImageFormat* imageFormat) {
    return shared_ptr<CudaImage>(new CudaImage(width, height, imageFormat, NULL));
}
shared_ptr<CudaImage> CudaImage::fromTexture(shared_ptr<G3D::Texture> texture) {
    auto result = shared_ptr<CudaImage>(new CudaImage(texture->width(), texture->height(), texture->format(), NULL));
    result->update(texture);
    return result;
}
void CudaImage::updateTexture(shared_ptr<G3D::Texture> texture) {
    shared_ptr<GLPixelTransferBuffer> ptb = GLPixelTransferBuffer::create(texture->width(), texture->height(), texture->format());
    // TODO: avoid useless allocation/copy
    G3D::Array<char> temp;
    temp.resize(sizeInMemory() / sizeof(char));
    copyTo(temp.getCArray());
    ptb->setData(temp.getCArray());
    texture->update(ptb);
}
void CudaImage::update(shared_ptr<G3D::Texture> texture) {
    shared_ptr<GLPixelTransferBuffer> ptb = texture->toPixelTransferBuffer();
    // TODO: avoid useless allocation/copy
    G3D::Array<char> temp;
    temp.resize(sizeInMemory() / sizeof(char));
    ptb->getData(temp.getCArray());
    updateFromMemory(temp.getCArray());
}

CudaImage::~CudaImage() {
    CUDA_SAFE_CALL(cudaFree(m_data));
    m_data = NULL;
}