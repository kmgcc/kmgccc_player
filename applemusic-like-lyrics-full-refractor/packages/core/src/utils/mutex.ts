// 一个异步互斥锁，用于控制并发

export function mutexifyFunction<
	F extends (...args: Args) => Promise<Result>,
	Args extends any[],
	Result,
>(func: F): F {
	const awaitingTasks: {
		resolve: (value: Result) => void;
		reject: (reason: any) => void;
		args: Args;
	}[] = [];
	function processNextTask() {
		const task = awaitingTasks[0];
		if (!task) return;
		func(...task.args)
			.then((value) => {
				task.resolve(value);
			})
			.catch((reason) => {
				task.reject(reason);
			})
			.finally(() => {
				awaitingTasks.shift();
				if (awaitingTasks.length > 0) {
					processNextTask();
				}
			});
	}
	return ((...args: Args) => {
		return new Promise<Result>((resolve, reject) => {
			awaitingTasks.push({ resolve, reject, args });
			if (awaitingTasks.length === 1) {
				processNextTask();
			}
		});
	}) as F;
}

export default mutexifyFunction;
