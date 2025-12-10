use axum::extract::Path;
use axum::http::{StatusCode, request::Parts};
use axum::{
    Json, Router,
    extract::{FromRequestParts, State},
    routing::{get, put},
};
use mongodb::{
    Client,
    bson::{doc, oid::ObjectId},
};
use serde::{Deserialize, Serialize};
use std::env;
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Todo {
    #[serde(rename = "_id", skip_serializing_if = "Option::is_none")]
    id: Option<ObjectId>,
    user_id: String,
    title: String,
    done: bool,
}

#[derive(Debug, Deserialize)]
struct NewTodo {
    title: String,
}

#[derive(Clone)]
struct AppState {
    collection: mongodb::Collection<Todo>,
}

#[derive(Debug, Deserialize)]
struct UpdateTodoPayload {
    done: bool,
}

struct CurrentUserId(String);

impl<S> FromRequestParts<S> for CurrentUserId
where
    S: Send + Sync,
{
    type Rejection = (StatusCode, String);

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let user_id = parts
            .headers
            .get("x-user-id")
            .and_then(|v| v.to_str().ok())
            .ok_or((
                StatusCode::UNAUTHORIZED,
                "x-user-id header is required".to_string(),
            ))?;
        Ok(CurrentUserId(user_id.to_string()))
    }
}

// GET /todos
async fn get_todos(
    State(state): State<AppState>,
    CurrentUserId(user_id): CurrentUserId,
) -> Json<Vec<Todo>> {
    let mut cursor = state
        .collection
        .find(doc! {"user_id": &user_id}) // 全件取得
        .await
        .expect("Failed to find todos");

    let mut result = Vec::new();
    while cursor.advance().await.expect("Cursor advance failed") {
        result.push(
            cursor
                .deserialize_current()
                .expect("Failed to deserialize todo"),
        );
    }

    Json(result)
}

// POST /todos
async fn create_todo(
    State(state): State<AppState>,
    CurrentUserId(user_id): CurrentUserId,
    Json(payload): Json<NewTodo>,
) -> Json<Todo> {
    // まず id なしの Todo を作る
    let todo_without_id = Todo {
        id: None,
        user_id,
        title: payload.title,
        done: false,
    };

    // 挿入結果から inserted_id (BSON) をもらう
    let insert_result = state
        .collection
        .insert_one(&todo_without_id)
        .await
        .expect("Failed to insert todo");

    // ObjectId を取り出す
    let oid = insert_result
        .inserted_id
        .as_object_id()
        .expect("inserted_id is not an ObjectId");

    // id を入れた形でクライアントに返す
    let todo_with_id = Todo {
        id: Some(oid),
        ..todo_without_id
    };

    Json(todo_with_id)
}

// PUT /todos/:id  （完了フラグの更新）
async fn update_todo(
    State(state): State<AppState>,
    CurrentUserId(user_id): CurrentUserId,
    Path(id): Path<String>,
    Json(payload): Json<UpdateTodoPayload>,
) -> StatusCode {
    // id は MongoDB の ObjectId 文字列
    let Ok(oid) = ObjectId::parse_str(&id) else {
        return StatusCode::BAD_REQUEST;
    };

    let filter = doc! { "_id": oid, "user_id": &user_id };
    let update = doc! { "$set": { "done": payload.done } };

    match state.collection.update_one(filter, update).await {
        Ok(result) if result.matched_count == 1 => StatusCode::OK,
        Ok(_) => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

// DELETE /todos/:id
async fn delete_todo(
    State(state): State<AppState>,
    CurrentUserId(user_id): CurrentUserId,
    Path(id): Path<String>,
) -> StatusCode {
    let Ok(oid) = ObjectId::parse_str(&id) else {
        return StatusCode::BAD_REQUEST;
    };

    let filter = doc! { "_id": oid, "user_id": &user_id };

    match state.collection.delete_one(filter).await {
        Ok(result) if result.deleted_count == 1 => StatusCode::OK,
        Ok(_) => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();
    // --- ① 設定を環境変数から読む -----------------------------------
    let mongodb_uri =
        env::var("MONGODB_URI").unwrap_or_else(|_| "mongodb://localhost:27017".to_string());
    // なぜ？ → ローカルでは今まで通り localhost、AWS / Docker では別の URI を渡せるようにするため

    let db_name = env::var("MONGODB_DB").unwrap_or_else(|_| "the_todo_app".to_string());
    // なぜ？ → 本番だけ DB 名を変えたい時にもコードを書き換えずに済む

    let port: u16 = env::var("PORT")
        .unwrap_or_else(|_| "3000".to_string())
        .parse()
        .expect("PORT must be a number");
    // なぜ？ → Heroku / Render / ECS などは PORT を環境変数で指定してくるパターンが多いから

    // --- ② MongoDB に接続 ---------------------------------------------
    let client = Client::with_uri_str(&mongodb_uri)
        .await
        .expect("Failed to connect to MongoDB");

    let db = client.database(&db_name);
    let collection = db.collection::<Todo>("todos");

    let state = AppState { collection };

    // --- ③ CORS（開発中なので全部許可のままで OK） -------------------------
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // --- ④ ルーター定義 -------------------------------------------------
    let app = Router::new()
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/{id}", put(update_todo).delete(delete_todo))
        .with_state(state)
        .layer(cors);

    // --- ⑤ サーバ起動 ---------------------------------------------------
    let addr = SocketAddr::from(([0, 0, 0, 0], port)); // ★ ここを変更
    println!("Listening on {}", addr);

    axum::serve(
        TcpListener::bind(addr).await.unwrap(),
        app.into_make_service(),
    )
    .await
    .unwrap();
}
