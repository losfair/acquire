run:
	LISTENERS=http:8000 REDIS_HOST=127.0.0.1 REDIS_PORT=6379 gleam run

run-info:
	ERL_FLAGS="-kernel logger_level info" gleam run

start-standard:
	curl localhost:8000/rooms?timestamp=$(shell date -u +'%s')000 -d @./games/standard.json 

build-frontend:
	cd frontend && npm run build
