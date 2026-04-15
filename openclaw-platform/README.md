# OpenClaw 多项目平台

这个目录现在采用**项目内 setup** 的模式：

- 平台只负责创建项目目录和初始文件
- 每个项目目录内都有自己的 `setup.sh`、`docker-compose.yml`、`.env`
- 后续操作直接进入项目目录执行 `./setup.sh`
- 不再维护平台级的 `start/stop/logs/list` 包装脚本

## 目录结构

```text
openclaw-platform/
  .env.defaults
  create-project.sh
  templates/
	docker-compose.project.yml
  scripts/
	setup.sh
  projects/
	<project-name>/
	  setup.sh
	  docker-compose.yml
	  .env
	  data/
		config/
		workspace/
```

## 全局默认配置

可以编辑 `openclaw-platform/.env.defaults`，为新建项目设置默认值。
创建时会把这些默认值写入每个项目自己的 `.env`。

## 使用方式

先创建项目：

```bash
./openclaw-platform/create-project.sh project-a
```

然后进入项目目录，按官方 setup 流程执行：

```bash
cd ./openclaw-platform/projects/project-a
./setup.sh
```

## 说明

- `create-project.sh` 会创建项目目录，并生成：
  - `setup.sh`
  - `docker-compose.yml`
  - `.env`
- 每个项目的 `data/config` 与 `data/workspace` 完全隔离
- 每个项目的 token 在创建时生成一次，并写入项目自己的 `.env`
- Gateway/Bridge 端口从 `18789` 开始按奇偶配对分配：
  - `gateway` 使用奇数端口（`18789`、`18791`、...）
  - `bridge` 使用 `gateway + 1`
- `projects/<name>/setup.sh` 是从 `openclaw-platform/scripts/setup.sh` 复制出来的独立文件；之后你只需要在项目目录里运行它


