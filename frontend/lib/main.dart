import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:universal_html/html.dart' as html;

// 1. Rustの /todos と対応するモデル
class Todo {
  final String? id; // ← int じゃなくて String? にする
  final String title;
  final bool done;

  Todo({required this.id, required this.title, required this.done});

  factory Todo.fromJson(Map<String, dynamic> json) {
    // MongoDB の _id は { "_id": { "$oid": "xxxxx" } } という形
    String? id;

    final rawId = json['_id']; // id じゃなくて _id を見る
    if (rawId is Map<String, dynamic>) {
      final oid = rawId[r'$oid'];
      if (oid is String) {
        id = oid;
      }
    } else if (rawId is String) {
      // とりあえず保険（もし文字列で返ってきた場合）
      id = rawId;
    }

    return Todo(
      id: id,
      title: json['title'] as String,
      done: json['done'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    // 新規作成時は _id は送らなくてOK（サーバー側で自動採番）
    return {'title': title, 'done': done};
  }
}

// ★ Rust API のベースURL
const String _baseUrl =
    kIsWeb
        ? 'http://127.0.0.1:3000' // Web のとき（Chrome）
        : 'http://192.168.0.188:3000';

final _uuid = Uuid();

Future<String> _getOrCreateUserId() async {
  if (kIsWeb) {
    // --- Webの場合：localStorageに永続保存 ---
    final stored = html.window.localStorage['user_id'];
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    final newId = _uuid.v4();
    html.window.localStorage['user_id'] = newId;
    return newId;
  }

  // --- スマホ/PC（通常のSharedPreferences） ---
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString('user_id');

  if (existing != null && existing.isNotEmpty) {
    return existing;
  }

  final newId = _uuid.v4();
  await prefs.setString('user_id', newId);
  return newId;
}

void main() {
  runApp(const MyApp());
}

// 2. アプリ全体のルート
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'The Todo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 156, 207, 228),
        ),
        useMaterial3: true,
      ),
      home: const TodoPage(),
    );
  }
}

// 3. TODO一覧ページ（状態を持つ）
class TodoPage extends StatefulWidget {
  const TodoPage({super.key});

  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  // 取得したTODOリスト
  List<Todo> _todos = [];
  // ローディング中かどうか
  bool _isLoading = false;
  // エラーがあればメッセージを入れる
  String? _errorMessage;

  BannerAd? _bannerAd;

  final TextEditingController _titleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBanner(); // ★ 追加：起動時に広告を読み込む
    _fetchTodos(); // 画面表示時に一度だけ呼ぶ
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _loadBanner() {
    // WebではAdMobが使えないので何もしない
    if (kIsWeb) return;

    // ★ Google公式のテスト用AdUnitID
    const testAndroidBannerId = 'ca-app-pub-3940256099942544/6300978111';
    const testIosBannerId = 'ca-app-pub-3940256099942544/2934735716';

    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final adUnitId = isIOS ? testIosBannerId : testAndroidBannerId;

    _bannerAd = BannerAd(
      size: AdSize.banner,
      adUnitId: adUnitId, // ↑ 今はテストIDでOK
      listener: BannerAdListener(
        onAdLoaded: (Ad ad) {
          // 読み込めたら画面を再描画してバナーを表示
          setState(() {});
        },
        onAdFailedToLoad: (Ad ad, LoadAdError error) {
          ad.dispose();
          // 失敗したらバナーは表示しない
          setState(() {
            _bannerAd = null;
          });
        },
      ),
      request: const AdRequest(),
    )..load(); // ★ ここで実際に広告のロードを開始
  }

  // 4. RustのAPIから /todos を取得する関数
  Future<void> _fetchTodos() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('$_baseUrl/todos');

      // ★ ここで user_id を取得
      final userId = await _getOrCreateUserId();

      // ★ x-user-id ヘッダーを付けてGET
      final res = await http.get(
        uri,
        headers: {
          'x-user-id': userId,
          'Content-Type': 'application/json', // なくても動くが付けておくと無難
        },
      );

      if (res.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(res.body);
        final todos =
            jsonList
                .map((e) => Todo.fromJson(e as Map<String, dynamic>))
                .toList();

        setState(() {
          _todos = todos;
        });
      } else {
        setState(() {
          _errorMessage = 'サーバエラー: ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '通信エラー: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 新規TODOを追加する
  Future<void> _addTodo() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      return;
    }

    setState(() {
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('$_baseUrl/todos');

      // ★ user_id を取得
      final userId = await _getOrCreateUserId();

      final res = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-user-id': userId, // ★ ここが重要
        },
        body: jsonEncode({'title': title, 'done': false}),
      );

      if (res.statusCode == 200 || res.statusCode == 201) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final newTodo = Todo.fromJson(json);

        setState(() {
          _titleController.clear();
          _todos = [..._todos, newTodo];
        });
      } else {
        setState(() {
          _errorMessage = '追加に失敗しました: ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '通信エラー: $e';
      });
    } /*finally {
      setState(() {
        _isLoading = false;
      });
    }*/
  }

  Future<void> _toggleDone(Todo todo) async {
    final index = _todos.indexWhere((t) => t.id == todo.id);
    if (index == -1) return;

    final old = _todos[index];
    final updated = Todo(id: old.id, title: old.title, done: !old.done);

    setState(() {
      _todos[index] = updated;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('$_baseUrl/todos/${todo.id}');

      // ★ user_id を取得
      final userId = await _getOrCreateUserId();

      final res = await http.put(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-user-id': userId, // ★ ここ
        },
        body: jsonEncode({'done': !todo.done}),
      );

      if (res.statusCode != 200) {
        setState(() {
          _todos[index] = old;
          _errorMessage = '更新に失敗しました: ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _todos[index] = old;
        _errorMessage = '通信エラー: $e';
      });
    }
  }

  Future<void> _deleteTodo(Todo todo) async {
    final index = _todos.indexWhere((t) => t.id == todo.id);
    if (index == -1) return;

    final oldList = List<Todo>.from(_todos);

    setState(() {
      _todos.removeAt(index);
      _errorMessage = null;
      //_isLoading = true;
    });

    try {
      final uri = Uri.parse('$_baseUrl/todos/${todo.id}');

      // ★ user_id を取得
      final userId = await _getOrCreateUserId();

      final res = await http.delete(
        uri,
        headers: {
          'x-user-id': userId, // ★ DELETE でも同じ
          'Content-Type': 'application/json',
        },
      );

      if (res.statusCode != 200) {
        setState(() {
          _todos = oldList;
          _errorMessage = '削除に失敗しました: ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _todos = oldList;
        _errorMessage = '通信エラー: $e';
      });
    } /*finally {
      setState(() {
        _isLoading = false;
      });
    }*/
  }

  // ---- 8. 未来感UIの build ----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true, // 背景グラデをAppBarの裏まで伸ばす
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            //const Icon(Icons.bolt, color: Colors.lightBlueAccent),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('The Todo', style: TextStyle(fontWeight: FontWeight.bold)),
                //Text('Flutter × Rust × MySQL', style: TextStyle(fontSize: 11)),
              ],
            ),
          ],
        ),
        /*actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchTodos,
          ),
        ],*/
      ),
      body: Stack(
        children: [
          // ---- 背景グラデーション ----
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF4facfe), // 明るめの青
                  Color(0xFF00f2fe), // シアン寄り
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // ---- メインのカードエリア ----
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      // 入力部分の「浮いたカード」
                      _buildInputCard(context),
                      const SizedBox(height: 16),
                      // 残りをリストに使う
                      Expanded(child: _buildBody()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      // ★ 画面下にバナー広告を固定表示（Webのときはnull）
      bottomNavigationBar:
          (kIsWeb || _bannerAd == null)
              ? null
              : SafeArea(
                child: SizedBox(
                  height: _bannerAd!.size.height.toDouble(),
                  child: AdWidget(ad: _bannerAd!),
                ),
              ),
    );
  }

  // ---- 9. 入力エリアカード ----
  Widget _buildInputCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        // ★ 濃いめブルーグレーのガラス感
        gradient: LinearGradient(
          colors: [
            const Color(0xFF0B5560).withValues(alpha: 0.95), // 左上：深めブルーグリーン
            const Color(0xFF0F766E).withValues(alpha: 0.98), // 右下：今のカードより少し暗い
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 18),
            spreadRadius: -14,
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _titleController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                hintText: 'New Todo',
                hintStyle: TextStyle(color: Colors.white70),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _addTodo(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _addTodo,
            icon: const Icon(Icons.send_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  // ---- 10. リスト部分（中身は状態に応じて出し分け） ----
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!));
    }

    if (_todos.isEmpty) {
      return const Center(
        child: Text('タスクはまだありません', style: TextStyle(color: Colors.white70)),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: _todos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (context, index) {
        final todo = _todos[index];
        return _buildTodoTile(todo);
      },
    );
  }

  Widget _buildTodoTile(Todo todo) {
    // ベースになる色（未完了・完了で少し変える）
    final baseColor =
        todo.done
            ? const Color.fromARGB(255, 30, 148, 79) // 完了
            : const Color(0xFF1ABC9C); // 未完了

    return GestureDetector(
      onTap: () => _toggleDone(todo),
      child: Container(
        // ★ 外側コンテナ：影専用（中身は透明）
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            // しっかり目のドロップシャドウ
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 28,
              offset: const Offset(0, 18),
              spreadRadius: -12, // 内側に絞る → 影が帯になりにくい
            ),
            // ほんのり外側ににじむ光
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.10),
              blurRadius: 6,
              offset: const Offset(0, 0),
              spreadRadius: -2,
            ),
          ],
        ),
        child: Container(
          // ★ 内側コンテナ：ガラス板そのもの
          //padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: const EdgeInsets.only(
            left: 12,
            right: 4, // ← ここを 16 → 6 くらいにする
            top: 3,
            bottom: 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            // 透け感のあるグラデーションでガラスっぽく
            gradient: LinearGradient(
              colors: [
                baseColor.withValues(alpha: 0.40), // 少し透けた色
                baseColor.withValues(alpha: 0.85), // 右下に向かって濃く
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            // 縁を少し明るくして“ガラスのエッジ”
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              // 左の丸いチェック
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                    width: 2.4,
                  ),
                  color:
                      todo.done ? Colors.white.withValues(alpha: 0.95) : null,
                ),
                child:
                    todo.done
                        ? const Icon(Icons.check, size: 16, color: Colors.green)
                        : null,
              ),
              const SizedBox(width: 12),
              // タイトル
              Expanded(
                child: Text(
                  todo.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    decoration:
                        todo.done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                    color:
                        todo.done
                            ? Colors.black.withValues(alpha: 0.87)
                            : Colors.white,
                  ),
                ),
              ),
              // ゴミ箱
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
                onPressed: () => _deleteTodo(todo),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
