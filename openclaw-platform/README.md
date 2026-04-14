# OpenClaw 多项目平台

这个目录用于在同一台主机上管理多个彼此隔离的 OpenClaw Docker 实例。

## 设计原则

- 每个项目在 `projects/<name>/` 下都有独立目录
- 每个项目都有自己的 `docker-compose.yml` 和 `.env`
- 每个项目的 `data/config` 与 `data/workspace` 完全隔离
- 每个项目的 token 只在创建时生成一次，并持久化在 `.env` 中
- 运行时统一使用 `docker compose -p ocp-<name>` 做命名空间隔离
- 模板变更不会自动影响已经创建的项目

## 目录结构

```text
openclaw-platform/
  .env.defaults
  templates/
	docker-compose.project.yml
  scripts/
	common.sh
	create-project.sh
	start-project.sh
	stop-project.sh
	logs-project.sh
	list-projects.sh
  projects/
	<project-name>/
	  docker-compose.yml
	  .env
	  data/
		config/
		workspace/
```

## 全局默认配置

可以编辑 `openclaw-platform/.env.defaults`，为新建项目设置平台级默认值。
项目自身 `.env` 中的同名配置会覆盖这些默认值。

## 使用方式

```bash
./openclaw-platform/platform.sh create project-a
./openclaw-platform/platform.sh start project-a
./openclaw-platform/platform.sh logs project-a
./openclaw-platform/platform.sh stop project-a
./openclaw-platform/platform.sh list
```

也可以直接调用脚本：

```bash
./openclaw-platform/scripts/create-project.sh project-a
./openclaw-platform/scripts/start-project.sh project-a
./openclaw-platform/scripts/logs-project.sh project-a
./openclaw-platform/scripts/stop-project.sh project-a
./openclaw-platform/scripts/list-projects.sh
```

## 说明

- `create-project.sh` 只创建目录与配置文件，不会自动启动容器
- `start-project.sh` 在真正 `up` 之前会执行预启动流程：
  - 自动执行权限修复（与官方 setup 一致，启动前执行 `chown`）
  - 首次启动时自动执行一次 onboarding（后续启动自动跳过）
  - 写入并同步 `gateway.mode=local` 与 `gateway.bind`
  - 预启动任一步失败会直接停止，不会继续启动容器
- 如果出现 `Missing config. Run openclaw setup...`，通常表示首次 onboarding 未成功完成；再次执行 `start` 会重新触发首次初始化
- Gateway/Bridge 端口从 `18789` 开始按奇偶配对分配：
  - `gateway` 使用奇数端口（`18789`、`18791`、...）
  - `bridge` 使用 `gateway + 1`
- 默认代理环境变量会写入每个项目的 `.env`，可按项目单独调整


