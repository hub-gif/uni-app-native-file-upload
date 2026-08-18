# uni-app-native-file-upload

uni-app（Vue 3 + App 5+）下的原生文件选择与 multipart 上传组件。

适用于从系统文件管理器选择 PDF、Word、Excel 等非媒体文件，并提交到自有后端。图片/视频请继续使用 `uni.chooseImage` / `uni.chooseVideo`。

**本仓库面向 uni-app Vue，不是 uni-app x。**

## 功能

- Android / iOS 系统文件选择器（任意类型）
- 按平台分流的 multipart 上传
- 可选：下载前选择系统可见的保存位置

| 平台 | 选择 | 上传 |
| --- | --- | --- |
| Android | `ACTION_OPEN_DOCUMENT` | HTML5+ `plus.uploader` |
| iOS | `UIDocumentPickerViewController` | 插件内 `URLSession`（`uploadNativeMultipart`） |

iOS 端不得将本插件返回的本地路径交给 `plus.uploader` 或 `uni.uploadFile`。5+ 无法稳定读取 UTS 落盘文件，常见结果是 HTTP 200 且表单字段正常，但服务端 `FILES` 为空。

## 环境要求

- HBuilderX 5.0+
- uni-app Vue 3，App-Android / App-iOS
- 含本插件的**自定义调试基座**（标准基座不含 UTS 实现）
- iOS 12+ / Android API 21+

## 安装

将插件目录复制到工程的 `uni_modules`：

```text
# HBuilderX 标准工程
uni_modules/native-file-picker/

# Vue CLI / src 目录工程
src/uni_modules/native-file-picker/
```

将 `js/uploadNativeFiles.ts` 复制到工程内（例如 `src/utils/uploadNativeFiles.ts`），按实际路径修改其中的插件 import。

首次接入或变更 `utssdk/app-ios`、`utssdk/app-android` 后，须重新制作并使用自定义基座。仅修改 JS 不必重打基座。

## 快速开始

```ts
import { chooseNativeFiles } from '@/uni_modules/native-file-picker'
import { uploadNativeFiles } from '@/utils/uploadNativeFiles'

chooseNativeFiles({
  count: 1,
  maxSizeMB: 20,
  success: async ({ files }) => {
    const file = files[0]
    const res = await uploadNativeFiles({
      url: 'https://example.com/api/upload/',
      header: {
        Authorization: 'Bearer <token>'
      },
      formData: {
        bizType: 'attachment'
      },
      files: [
        {
          path: file.path,
          fieldName: 'files',
          name: file.name,
          mimeType: file.type
        }
      ]
    })
    console.log(res.statusCode, res.data)
  },
  fail: (error) => {
    console.error(error.errMsg)
  }
})
```

约定：

- `header` 不要设置 `Content-Type`，边界由上传实现写入。
- `formData` 的值必须是字符串。
- `fieldName` 与后端接收字段一致（示例为 `files`）。
- 若后端启用 Django `APPEND_SLASH`，URL 应带末尾斜杠，避免 301 后 iOS 丢失 `Authorization`。

## API

### `chooseNativeFiles(options)`

打开系统文件选择器，将选中文件复制到应用沙盒后回调。

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `count` | `number` | `1` | 最多选择数量 |
| `maxSizeMB` | `number` | `50` | 单文件大小上限 |
| `destDir` | `string` | — | iOS 可选，落盘根目录的绝对路径 |
| `success` | `(res) => void` | — | `res.files`: `{ path, name, size, type }[]` |
| `fail` | `(err) => void` | — | `err.errMsg` |
| `progress` | `(p) => void` | — | 拷贝进度：`name, index, count, loaded, total, progress` |

iOS 的 `path` 为本地绝对路径，供 `uploadNativeMultipart` 直接读取。

### `uploadNativeFiles(request, hooks?)`

按运行时选择上传实现，返回 `{ statusCode, data }`。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | `string` | 上传地址 |
| `files` | `Array` | `path` / `fieldName` / `name?` / `mimeType?` |
| `header` | `Record<string, string>` | 请求头，通常含 `Authorization` |
| `formData` | `Record<string, string>` | 额外表单字段 |
| `timeoutSeconds` | `number` | Android `plus.uploader` 超时，默认 120 |

`hooks.onProgress(progress, sent?, total?)` 中 `progress` 最大为 99，由调用方在成功后置 100。

### `uploadNativeMultipart(options)`（iOS）

插件原生方法。`uploadNativeFiles` 在 iOS 上会调用它。也可直接使用：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | `string` | 上传地址 |
| `headersJson` | `string` | `JSON.stringify(header)` |
| `formDataJson` | `string` | `JSON.stringify(formData)` |
| `files` | `Array` | 同选择结果，`fieldName` 为表单文件键 |
| `success` / `fail` / `progress` | `function` | 回调 |

### 保存到系统目录（可选）

| 方法 | 说明 |
| --- | --- |
| `chooseNativeSaveDestination` | 选择保存位置，返回 `token`；用户取消时 `canceled === true` |
| `writeNativeSavedFile` | 将已下载的本地文件写入所选位置 |

Android 使用 `ACTION_CREATE_DOCUMENT`（初始目录为系统下载）；iOS 先选择文件夹再写入。

## 平台说明

HTML5+ 使用虚拟路径（`_doc`、`_www` 等），UTS 使用沙盒绝对路径。二者同属一个应用，但没有自动映射。

因此：

1. Android：插件拷贝到应用缓存后，`plus.uploader` 可以读取，走 5+ 上传。
2. iOS：将文件写入 `_doc` 或先调用 `plus.io.convertLocalFileSystemURL('_doc')` 再拷贝，仍不能保证 5+ 上传带上文件体。须使用本插件的 `URLSession` 上传。
3. 不存在可用的 `plus.io.chooseFile`。App 端选择非媒体文件，iOS 必须使用原生插件。

修改插件原生代码时注意 UTS 转译限制，否则云打包失败：

- 导出给 JS 的 Swift 方法不要使用 `throws`，错误通过 completion 返回。
- 选项中的数组在 Swift 侧为可选类型，须先写 `options.files ?? []` 再访问 `length`。
- 不要将 `String?` 用于布尔判断（例如 `if (options.mimeType)`）。
- Android 回调参数名不要使用 `__`。
- `chooseNativeFiles`、`uploadNativeMultipart` 须为 `export function`，并添加 `@UTSJS.keepAlive`。

## 目录结构

```text
uni_modules/native-file-picker/   # UTS 插件，复制到工程 uni_modules
  package.json
  utssdk/
    interface.uts
    app-android/
    app-ios/
js/uploadNativeFiles.ts               # 选择后的双端上传封装
```

## License

可在自有项目中使用和修改。业务接口、鉴权与字段名由接入方自行实现。
