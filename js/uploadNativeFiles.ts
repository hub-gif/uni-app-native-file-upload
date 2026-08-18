/**
 * iOS：插件 URLSession 上传（UTS 选出的文件不要交给 5+）
 * Android：plus.uploader
 * 其它：uni.uploadFile
 */
// #ifdef APP-PLUS
import { uploadNativeMultipart } from '@/uni_modules/native-file-picker'
// #endif

export type NativeUploadInputFile = {
  path: string
  fieldName: string
  name?: string
  mimeType?: string
  size?: number
}

export type NativeUploadRequest = {
  url: string
  files: NativeUploadInputFile[]
  formData?: Record<string, string>
  header?: Record<string, string>
  timeoutSeconds?: number
}

export type NativeUploadResult = {
  statusCode: number
  data: string
}

export type NativeUploadHooks = {
  onProgress?: (progress: number, sent?: number, total?: number) => void
  abort?: { abort: () => void }
}

function isIos(): boolean {
  try {
    const info = uni.getSystemInfoSync() as { osName?: string; platform?: string }
    return String(info.osName || info.platform || '').toLowerCase().includes('ios')
  } catch {
    return false
  }
}

function plusUploader() {
  return (globalThis as typeof globalThis & {
    plus?: {
      uploader?: {
        createUpload: (
          url: string,
          options: { method: 'POST'; timeout: number },
          completed: (task: {
            responseText?: string
            uploadedSize?: number
            totalSize?: number
            addData: (key: string, value: string) => boolean
            addFile: (path: string, options: { key: string; name?: string; mime?: string }) => boolean
            addEventListener: (event: 'statechanged', listener: (task: any) => void, capture?: boolean) => void
            setRequestHeader: (name: string, value: string) => void
            start: () => void
            abort: () => void
          }, statusCode: number) => void
        ) => any
      }
    }
  }).plus?.uploader
}

function uploadIos(request: NativeUploadRequest, hooks: NativeUploadHooks = {}): Promise<NativeUploadResult> {
  return new Promise((resolve, reject) => {
    // #ifdef APP-PLUS
    if (typeof uploadNativeMultipart !== 'function') {
      reject(new Error('当前基座没有原生上传，请重新制作 iOS 自定义基座'))
      return
    }
    uploadNativeMultipart({
      url: request.url,
      headersJson: JSON.stringify(request.header || {}),
      formDataJson: JSON.stringify(request.formData || {}),
      files: request.files.map((file) => ({
        path: file.path,
        fieldName: file.fieldName,
        name: file.name || 'file',
        mimeType: file.mimeType || 'application/octet-stream'
      })),
      success: (result) => resolve({ statusCode: result.statusCode, data: result.data }),
      fail: (error) => reject(new Error(error.errMsg || '上传失败')),
      progress: (event) => {
        hooks.onProgress?.(
          Math.max(0, Math.min(99, Number(event.progress) || 0)),
          event.loaded,
          event.total
        )
      }
    })
    return
    // #endif
    reject(new Error('当前环境不支持 iOS 原生上传'))
  })
}

function uploadAndroid(request: NativeUploadRequest, hooks: NativeUploadHooks = {}): Promise<NativeUploadResult> {
  const uploader = plusUploader()
  if (!uploader) return Promise.reject(new Error('当前环境不支持 plus.uploader'))
  return new Promise((resolve, reject) => {
    let settled = false
    const task = uploader.createUpload(
      request.url,
      { method: 'POST', timeout: request.timeoutSeconds || 120 },
      (completedTask, statusCode) => {
        if (settled) return
        settled = true
        resolve({ statusCode, data: completedTask.responseText || '' })
      }
    )
    for (const [name, value] of Object.entries(request.header || {})) {
      task.setRequestHeader(name, value)
    }
    for (const [name, value] of Object.entries(request.formData || {})) {
      if (!task.addData(name, value)) {
        settled = true
        reject(new Error(`无法添加上传字段：${name}`))
        return
      }
    }
    for (const file of request.files) {
      if (!task.addFile(file.path, {
        key: file.fieldName,
        name: file.name,
        mime: file.mimeType
      })) {
        settled = true
        reject(new Error(`无法读取「${file.name || '所选文件'}」，请重新选择`))
        return
      }
    }
    task.addEventListener('statechanged', (uploadTask) => {
      const sent = Number(uploadTask.uploadedSize) || 0
      const total = Number(uploadTask.totalSize) || 0
      if (!total) return
      hooks.onProgress?.(Math.max(0, Math.min(99, Math.round((sent / total) * 100))), sent, total)
    }, false)
    task.start()
  })
}

function uploadUni(request: NativeUploadRequest, hooks: NativeUploadHooks = {}): Promise<NativeUploadResult> {
  const first = request.files[0]
  return new Promise((resolve, reject) => {
    const task = uni.uploadFile({
      url: request.url,
      filePath: first.path,
      name: first.fieldName,
      formData: request.formData || {},
      header: request.header || {},
      success: (res) => resolve({ statusCode: res.statusCode, data: String(res.data || '') }),
      fail: (error) => reject(new Error(error.errMsg || '上传失败'))
    })
    task.onProgressUpdate?.((event) => {
      hooks.onProgress?.(Number(event.progress) || 0, Number(event.totalBytesSent) || undefined, Number(event.totalBytesExpectedToSend) || undefined)
    })
  })
}

export function uploadNativeFiles(
  request: NativeUploadRequest,
  hooks: NativeUploadHooks = {}
): Promise<NativeUploadResult> {
  if (!request.files.length) return Promise.reject(new Error('请选择上传文件'))
  if (isIos()) return uploadIos(request, hooks)
  if (plusUploader()) return uploadAndroid(request, hooks)
  return uploadUni(request, hooks)
}
