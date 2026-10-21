# 核心发帖接口回归

这些 RSpec 请求测试需要独立的 Discourse 测试环境；不能在生产环境执行。测试使用合成用户与分类，不使用真实登录账号。

在已准备 PostgreSQL、Redis 与测试数据库的 Discourse 源码目录中运行：

```sh
RAILS_ENV=test LOAD_PLUGINS=0 bundle exec rspec /path/to/theme/tests/server/topic-groups-posts_spec.rb
```

测试请求遵循核心 `frontend/discourse/app/adapters/post.js` 的 JSON 请求形式：`POST /posts.json`、`nested_post: true`。新话题使用 `category` 字段；这与核心 composer 的创建序列化一致。成功响应包含 `post`，待审核响应包含 `action: enqueued` 和 `pending_post`。

覆盖两字标题直接开聊、待审核、私有分类拒绝、公开只读分类拒绝、匿名拒绝与长度校验失败。`typing_duration_msecs` 发送零，不延时或编造输入时长。测试内使用产品的短消息设置：标题至少 2 字、首帖及回复至少 1 字，关闭仅按首帖输入速度自动禁言；其他权限和审批仍由核心处理。需要同时设置 `min_post_length`，因为初步与排队校验也会使用它。

这些设置仅用于隔离测试。主题不会自动修改站点后台；真实站点是否关闭 `auto_silence_fast_typers_on_first_post` 应根据短中文内容的误判情况和社区管理需要评估，不能把测试配置理解为关闭其他审核或限流的建议。

1.2.0 发布前已在 Discourse 2026.7.3 的隔离 Compose 环境中，以 `LOAD_PLUGINS=0` 通过 **6 examples, 0 failures**。测试不依赖专用认证插件。这验证核心接口，不替代 GJS 编译和浏览器交互验收。

2026-10-22：移除专用登录插件设置后，以 `LOAD_PLUGINS=0` 仅加载核心重新验证，**6 examples, 0 failures**，seed `56546`；测试不依赖任何登录插件。
