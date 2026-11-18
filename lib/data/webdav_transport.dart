import 'dart:convert';

import 'package:dio/dio.dart';

/// 同步失败的类型，UI 据此给出可操作的提示，而不是抛一段英文异常给用户。
enum SyncFailure {
  /// 服务器地址没填 / 不是 http(s)。
  badConfig,

  /// 用户名或密码错误（401）。
  auth,

  /// 账号没有该目录的读写权限（403）。
  forbidden,

  /// 远端文件或目录不存在（404）。
  notFound,

  /// 服务器活着，但不接受 WebDAV 动词（405 / 501）。
  ///
  /// 实际遇到这个，九成是**地址填错了**：漏了 `/dav` 之类的端点路径，
  /// 或者填成了服务商的网页地址 —— 网页只认 GET/POST，PROPFIND 一律 405。
  notWebDav,

  /// 服务器不允许客户端自动建目录（MKCOL 405 且目录确实不存在）。
  ///
  /// 飞牛 fnOS 就是这样：必须在它的「文件管理」里手动建好目录，
  /// 客户端 MKCOL 一律 405。这种情况**不能**把 405 当成「目录已存在」放过，
  /// 否则后面 PUT 到不存在的目录，用户只会看到另一个没头没脑的 405。
  mkdirUnsupported,

  /// 远端路径指向的是一个**文件夹**而不是文件（飞牛等会直接对 GET 目录回 405）。
  pathIsFolder,

  /// 远端文件存在，但不是本 App 写的同步文件：中止，绝不覆盖别人的数据。
  unrecognized,

  /// 每日备份没做成：为了让「后悔药」始终有效，这次同步直接中止。
  backupFailed,

  /// 服务器返回了其它错误。
  server,

  /// 连不上（域名错、无网络、证书问题）。
  network,

  /// 连接或读取超时。
  timeout,
}

class SyncException implements Exception {
  const SyncException(this.failure, {this.statusCode, this.detail});

  final SyncFailure failure;
  final int? statusCode;
  final String? detail;

  @override
  String toString() => 'SyncException($failure'
      '${statusCode == null ? '' : ', $statusCode'}'
      '${detail == null ? '' : ', $detail'})';
}

/// 远端目录里的一项，用于「浏览远端文件夹」。
class RemoteEntry {
  const RemoteEntry({required this.name, required this.isCollection});

  final String name;
  final bool isCollection;

  @override
  String toString() => 'RemoteEntry($name, collection: $isCollection)';
}

/// 同步用的传输边界：真实实现走 WebDAV，测试用 Fake。
///
/// 这样合并逻辑与网络解耦：单测可以覆盖「远端没有文件 / 远端是脏数据 /
/// 上传失败」等分支，而不需要真的连网盘。
abstract class SyncTransport {
  /// 验证地址、账号、权限是否可用（不读不写业务数据）。
  Future<void> probe(String remotePath);

  /// 列出某个目录下的直接子项（PROPFIND Depth:1）。
  ///
  /// 存在的意义：各家 WebDAV 的「根」映射到哪一层完全不一样 ——
  /// 飞牛 fnOS 的团队文件夹在 `/团队文件-dav/` 下，坚果云在 `/dav/` 下，
  /// 让用户照文档猜路径必然出错，不如直接把目录列出来让他点。
  Future<List<RemoteEntry>> list(String path);

  /// 下载远端文件；`null` 表示远端还没有这个文件（首次同步）。
  Future<String?> download(String remotePath);

  /// 上传整份快照，通常覆盖同名文件。
  Future<void> upload(String remotePath, String content);

  /// 删除远端文件（用于清理超出保留份数的旧备份）。
  ///
  /// 幂等：文件已经不在了（404）视为成功 —— 清理是顺带做的事，
  /// 不该因为「上一次删了一半」而每次都报错。
  Future<void> delete(String remotePath);

  /// 逐级创建远端目录（已存在则忽略）。
  Future<void> ensureDirectory(String remotePath);
}

/// 最小可用 WebDAV 客户端：只用到 GET / PUT / MKCOL / PROPFIND。
///
/// 没有引入 webdav 专用包：这几个动词用 dio 的 `Options(method: ...)` 就能发，
/// 少一个依赖、也方便自己控制超时与错误映射。
class WebDavTransport implements SyncTransport {
  WebDavTransport({
    required String baseUrl,
    required String username,
    required String password,
    Dio? dio,
  })  : _baseUrl = _normalizeBase(baseUrl),
        _authHeader = username.isEmpty
            ? null
            : 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 25),
                sendTimeout: const Duration(seconds: 25),
                // 状态码由本类自己映射成 SyncException，不让 dio 先抛一堆类型。
                validateStatus: (_) => true,
                responseType: ResponseType.plain,
              ),
            );

  final String _baseUrl;

  /// `multistatus` 里一层 `<response>`；属性写在开始标签上，所以前缀要可选。
  static final RegExp _responseBlock = RegExp(
    r'<(?:[A-Za-z0-9._-]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9._-]+:)?response>',
  );
  static final RegExp _hrefTag = RegExp(
    r'<(?:[A-Za-z0-9._-]+:)?href\s*>([\s\S]*?)</(?:[A-Za-z0-9._-]+:)?href\s*>',
  );

  /// 认证头挂在每个请求上，而不是 BaseOptions：注入自定义 Dio 时也一定生效。
  final String? _authHeader;
  final Dio _dio;

  static String _normalizeBase(String raw) {
    final value = raw.trim();
    if (value.isEmpty) throw const SyncException(SyncFailure.badConfig);
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      throw const SyncException(SyncFailure.badConfig);
    }
    return value.endsWith('/') ? value : '$value/';
  }

  /// 相对路径逐段编码（保留 `/`），中文目录名也能正确请求。
  String _url(String path) {
    final encoded = path
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .map((s) => Uri.encodeComponent(s.trim()))
        .join('/');
    return '$_baseUrl$encoded';
  }

  Future<Response<String>> _request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? headers,
  }) async {
    try {
      return await _dio.request<String>(
        _url(path),
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          // 关键：状态码一律由本类映射成 SyncException。
          // 若只依赖 BaseOptions，注入自定义 Dio（测试 / 复用实例）时会退回
          // dio 默认的 2xx 判定，401/404 就直接变成 DioException 了。
          validateStatus: (_) => true,
          headers: <String, dynamic>{
            if (_authHeader != null) 'Authorization': _authHeader,
            ...?headers,
            if (data != null)
              Headers.contentTypeHeader: Headers.jsonContentType,
          },
        ),
      );
    } on DioException catch (error) {
      throw _mapDioError(error);
    }
  }

  static SyncException _mapDioError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const SyncException(SyncFailure.timeout);
      case DioExceptionType.badResponse:
        return SyncException(
          SyncFailure.server,
          statusCode: error.response?.statusCode,
        );
      case DioExceptionType.badCertificate:
      case DioExceptionType.connectionError:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        return const SyncException(SyncFailure.network);
    }
  }

  static SyncException _statusFailure(
    int status, {
    required String method,
    required String url,
    String? body,
  }) {
    final detail = _describeRequest(method, url, status, body);
    if (status == 401) {
      return SyncException(SyncFailure.auth,
          statusCode: status, detail: detail);
    }
    if (status == 403) {
      return SyncException(
        SyncFailure.forbidden,
        statusCode: status,
        detail: detail,
      );
    }
    if (status == 404) {
      return SyncException(
        SyncFailure.notFound,
        statusCode: status,
        detail: detail,
      );
    }
    // 405 说明「这个动词我不认」；501 是「这个动词我没实现」。
    // 两者都不是普通服务器错误：排查方向是地址，不是网络。
    if (status == 405 || status == 501) {
      return SyncException(
        SyncFailure.notWebDav,
        statusCode: status,
        detail: detail,
      );
    }
    return SyncException(SyncFailure.server,
        statusCode: status, detail: detail);
  }

  /// 非 2xx 时的统一出口。
  ///
  /// 405 / 501 多做一件事：探一下同主机的常见端点，把「能用的地址」写进提示。
  /// 实际最常见的失败原因就是地址少了 `/dav` 这一节，与其让用户猜，
  /// 不如直接把探测结果给他。
  Future<SyncException> _failureFor(
    int status, {
    required String method,
    required String url,
    String? body,
  }) async {
    final failure = _statusFailure(
      status,
      method: method,
      url: url,
      body: body,
    );
    if (failure.failure != SyncFailure.notWebDav) return failure;

    final suggestion = await _guessEndpoint();
    if (suggestion == null) return failure;
    return SyncException(
      SyncFailure.notWebDav,
      statusCode: status,
      detail: '${failure.detail} · 可用地址：$suggestion',
    );
  }

  /// 错误详情带上「哪个动词、哪个地址、服务器怎么说的」，
  /// 出问题时用户一眼能看出是地址写错还是权限问题，不用再猜。
  static String _describeRequest(
    String method,
    String url,
    int status,
    String? body,
  ) {
    final text = StringBuffer('$method $url → $status');
    final extra = _snippet(body);
    if (extra != null) text.write(' · $extra');
    final full = text.toString();
    return full.length <= 200 ? full : '${full.substring(0, 200)}…';
  }

  @override
  Future<void> probe(String remotePath) async {
    // PROPFIND Depth:0 是 WebDAV 里最轻的「这个地址你能进吗」探测。
    final response = await _request(
      'PROPFIND',
      '',
      headers: <String, dynamic>{'Depth': '0'},
    );
    final status = response.statusCode ?? 0;
    if (status == 207 || status == 200) return;
    throw await _failureFor(
      status,
      method: 'PROPFIND',
      url: _baseUrl,
      body: response.data,
    );
  }

  /// 探一探 `dav/`、`webdav/` 这类常见端点，只作为错误提示里的建议。
  ///
  /// 注意：这里任何异常都吞掉 —— 探路失败不代表原始错误有变化，
  /// 不能让它盖掉真正要给用户看的 405。
  Future<String?> _guessEndpoint() async {
    for (final candidate in <String>['${_baseUrl}dav/', '${_baseUrl}webdav/']) {
      final probe = await _propfind(candidate);
      if (probe.status == 207 || probe.status == 200) return candidate;
    }
    return null;
  }

  /// 只看状态码（与资源类型）的轻量 PROPFIND：用于探路，绝不抛异常。
  /// `status` 为 -1 表示请求本身没发出去（网络 / 证书问题）。
  Future<_PropfindResult> _propfind(String url) async {
    final first = await _propfindOnce(url);
    // 少数服务器（飞牛 fnOS 就是）对「集合」只认带末尾斜杠的地址，
    // 不带斜杠一律 404。不补这一次，已存在的目录会被我们误判成不存在。
    if (first.status == 404 && !url.endsWith('/')) {
      final retry = await _propfindOnce('$url/');
      if (retry.status >= 200 && retry.status < 300) return retry;
    }
    return first;
  }

  Future<_PropfindResult> _propfindOnce(String url) async {
    try {
      final response = await _dio.request<String>(
        url,
        options: Options(
          method: 'PROPFIND',
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          headers: <String, dynamic>{
            if (_authHeader != null) 'Authorization': _authHeader,
            'Depth': '0',
          },
        ),
      );
      final body = response.data ?? '';
      return _PropfindResult(
        response.statusCode ?? -1,
        // namespace 前缀各服务端不同（D: / d: / lp1:），只认关键字就够了。
        isCollection: body.contains('collection'),
      );
    } on Object {
      return const _PropfindResult(-1);
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final dir = _cleanPath(path);
    final response = await _request(
      'PROPFIND',
      dir,
      headers: <String, dynamic>{'Depth': '1'},
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw await _failureFor(
        status,
        method: 'PROPFIND',
        url: _dirUrl(dir),
        body: response.data,
      );
    }
    return _parseEntries(response.data ?? '', dir);
  }

  /// 浏览器式路径：只保留有效段，避免 `//a//b/` 这类用户输入导致地址畸形。
  static String _cleanPath(String path) => path
      .trim()
      .split('/')
      .where((s) => s.trim().isNotEmpty)
      .map((s) => s.trim())
      .join('/');

  /// 目录地址补末尾斜杠 —— 飞牛 / Nextcloud 都会因为缺斜杠把集合当成文件。
  String _dirUrl(String dir) {
    if (dir.isEmpty) return _baseUrl;
    final url = _url(dir);
    return url.endsWith('/') ? url : '$url/';
  }

  /// 解析 `multistatus`：取出子项名字与「是不是文件夹」。
  ///
  /// 不引 XML 依赖：WebDAV 的响应形状很固定，response/Href 两层标签足够，
  /// 而且 namespace 前缀各家不同（`D:` / `d:` / `lp1:`），正则要按「可选前缀」写。
  List<RemoteEntry> _parseEntries(String xml, String requested) {
    final baseSegments = _segmentsOf(_baseUrl);
    final requestedSegments = _segmentsOf(requested);

    final entries = <RemoteEntry>[];
    for (final block in _responseBlock.allMatches(xml)) {
      final body = block.group(1) ?? '';
      final href = _hrefTag.firstMatch(body)?.group(1)?.trim() ?? '';
      if (href.isEmpty) continue;

      var segments = _segmentsOf(href);
      // 服务器可能给绝对路径（/dav/team/），也可能给完整 URL，统一剥掉根前缀。
      if (_startsWith(segments, baseSegments)) {
        segments = segments.sublist(baseSegments.length);
      }
      if (!_startsWith(segments, requestedSegments)) continue;
      final tail = segments.sublist(requestedSegments.length);
      // tail 为空 = 目录自身；长度 >1 = 更深层，Depth:1 不该出现，容错忽略。
      if (tail.length != 1) continue;

      entries.add(
        RemoteEntry(
          name: tail.single,
          isCollection: body.contains('collection'),
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isCollection != b.isCollection) return a.isCollection ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return entries;
  }

  static List<String> _segmentsOf(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const <String>[];
    final uri = Uri.tryParse(text);
    final segments = uri == null
        ? text.split('/')
        : uri.pathSegments; // pathSegments 已经做过百分号解码，中文目录名可直接用
    return segments.where((s) => s.isNotEmpty).toList();
  }

  static bool _startsWith(List<String> value, List<String> prefix) {
    if (value.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (value[i] != prefix[i]) return false;
    }
    return true;
  }

  @override
  Future<String?> download(String remotePath) async {
    final response = await _request('GET', remotePath);
    final status = response.statusCode ?? 0;
    // 404 是「首次同步，远端还没这个文件」，属于正常分支。
    if (status == 404) return null;
    if (status == 405 || status == 501) {
      // 405 对 GET 有三种完全不同的含义，必须用 PROPFIND 区分：
      //   路径是文件夹（飞牛 fnOS 就这么回） → 提示用户填文件名；
      //   文件确实不存在（部分服务器用 405 代替 404） → 按首次同步继续；
      //   文件在但不许读 → 中止，否则会用本机数据覆盖远端。
      final probe = await _propfind(_url(remotePath));
      final exists = probe.status >= 200 && probe.status < 300;
      if (exists && probe.isCollection) {
        throw SyncException(
          SyncFailure.pathIsFolder,
          statusCode: status,
          detail: 'GET ${_url(remotePath)} → $status · 这是文件夹，不是文件',
        );
      }
      if (exists) {
        throw await _failureFor(
          status,
          method: 'GET',
          url: _url(remotePath),
          body: response.data,
        );
      }
      if (probe.status == 404) return null;
      throw await _failureFor(
        status,
        method: 'GET',
        url: _url(remotePath),
        body: response.data,
      );
    }
    if (status < 200 || status >= 300) {
      throw await _failureFor(
        status,
        method: 'GET',
        url: _url(remotePath),
        body: response.data,
      );
    }
    return response.data ?? '';
  }

  @override
  Future<void> upload(String remotePath, String content) async {
    final response = await _request('PUT', remotePath, data: content);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw await _failureFor(
        status,
        method: 'PUT',
        url: _url(remotePath),
        body: response.data,
      );
    }
  }

  @override
  Future<void> delete(String remotePath) async {
    final response = await _request('DELETE', remotePath);
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    // 已经不在了就是「删过了」：清理旧备份是顺带动作，不该因此报错。
    if (status == 404) return;
    throw await _failureFor(
      status,
      method: 'DELETE',
      url: _url(remotePath),
      body: response.data,
    );
  }

  @override
  Future<void> ensureDirectory(String remotePath) async {
    final slash = remotePath.lastIndexOf('/');
    final dir = slash <= 0 ? '' : remotePath.substring(0, slash);
    if (dir.isEmpty) return;

    var accumulated = '';
    for (final segment in dir.split('/').where((s) => s.trim().isNotEmpty)) {
      accumulated = accumulated.isEmpty
          ? segment.trim()
          : '$accumulated/${segment.trim()}';
      final response = await _request('MKCOL', accumulated);
      final status = response.statusCode ?? 0;
      if (status == 405) {
        // RFC 4918 说 405 = 「集合已存在」，但飞牛 fnOS 是「不允许客户端建目录」，
        // 同样回 405。所以必须用 PROPFIND 确认到底存不存在，再决定放过还是报错。
        final probe = await _propfind(_url(accumulated));
        if (probe.status >= 200 && probe.status < 300) continue;
        if (probe.status == 404) {
          // 既然建不了目录，就把「上级目录里实际有什么」直接列出来。
          // 各家 WebDAV 的根映射差别极大（飞牛的团队文件夹在 /团队文件-dav/ 下），
          // 让用户照文档猜前缀必然出错，看到真实目录名就能自己纠正。
          final slash = accumulated.lastIndexOf('/');
          final parent = slash <= 0 ? '' : accumulated.substring(0, slash);
          final siblings = await _safeList(parent);
          throw SyncException(
            SyncFailure.mkdirUnsupported,
            statusCode: status,
            detail: 'MKCOL ${_url(accumulated)} → 405 · 目录不存在，'
                '服务器不允许自动创建'
                '${siblings.isEmpty ? '' : ' · 上级目录现有：${siblings.join('、')}'}',
          );
        }
        // 探不出来（网络 / 服务器也不认 PROPFIND 之外的写法）就沿用旧逻辑放过，
        // 让后面的 GET / PUT 把真实原因报出来，别在这里误杀。
        continue;
      }
      if (status < 300) continue;
      throw await _failureFor(
        status,
        method: 'MKCOL',
        url: _url(accumulated),
        body: response.data,
      );
    }
  }

  /// 列目录的「绝不出错」版本：只为了把提示写得更具体，任何失败都当没列到。
  Future<List<String>> _safeList(String path) async {
    try {
      final entries = await list(path);
      return entries
          .take(8)
          .map((e) => e.isCollection ? '${e.name}/' : e.name)
          .toList();
    } on Object {
      return const <String>[];
    }
  }

  /// 错误详情只留前 180 个字符，避免把整个 HTML 错误页塞进 SnackBar。
  static String? _snippet(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    final text = body.trim();
    return text.length <= 180 ? text : '${text.substring(0, 180)}…';
  }
}

/// PROPFIND Depth:0 的轻量结果：状态码 + 该路径是不是集合（文件夹）。
class _PropfindResult {
  const _PropfindResult(this.status, {this.isCollection = false});

  final int status;
  final bool isCollection;
}
