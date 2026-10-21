/* https://github.com/tiann/KernelSU/tree/main/js / https://www.npmjs.com/package/kernelsu */

let callbackCounter = 0;
function getUniqueCallbackName(prefix) {
  return `${prefix}_callback_${Date.now()}_${callbackCounter++}`;
}

// 当前 WebView 是否提供了内核接口
// 非 KernelSU 的模块管理器可能没有 ksu 对象，直接调用会让整个页面初始化抛异常
function hasKernelInterface() {
  return typeof ksu !== "undefined" && ksu !== null && typeof ksu.exec === "function";
}

export function exec(command, options) {
  if (typeof options === "undefined") {
    options = {};
  }

  return new Promise((resolve, reject) => {
    if (!hasKernelInterface()) {
      resolve({ errno: -1, stdout: "", stderr: "当前环境不支持内核接口，无法执行命令" });
      return;
    }

    // Generate a unique callback function name
    const callbackFuncName = getUniqueCallbackName("exec");

    // Define the success callback function
    window[callbackFuncName] = (errno, stdout, stderr) => {
      resolve({ errno, stdout, stderr });
      cleanup(callbackFuncName);
    };

    function cleanup(successName) {
      delete window[successName];
    }

    try {
      ksu.exec(command, JSON.stringify(options), callbackFuncName);
    } catch (error) {
      reject(error);
      cleanup(callbackFuncName);
    }
  });
}

function Stdio() {
    this.listeners = {};
  }
  
  Stdio.prototype.on = function (event, listener) {
    if (!this.listeners[event]) {
      this.listeners[event] = [];
    }
    this.listeners[event].push(listener);
  };
  
  Stdio.prototype.emit = function (event, ...args) {
    if (this.listeners[event]) {
      this.listeners[event].forEach((listener) => listener(...args));
    }
  };
  
  function ChildProcess() {
    this.listeners = {};
    this.stdin = new Stdio();
    this.stdout = new Stdio();
    this.stderr = new Stdio();
  }
  
  ChildProcess.prototype.on = function (event, listener) {
    if (!this.listeners[event]) {
      this.listeners[event] = [];
    }
    this.listeners[event].push(listener);
  };
  
  ChildProcess.prototype.emit = function (event, ...args) {
    if (this.listeners[event]) {
      this.listeners[event].forEach((listener) => listener(...args));
    }
  };
  
  export function spawn(command, args, options) {
    if (typeof args === "undefined") {
      args = [];
    } else if (!(args instanceof Array)) {
        // allow for (command, options) signature
        options = args;
    }
    
    if (typeof options === "undefined") {
      options = {};
    }
  
    const child = new ChildProcess();
    const childCallbackName = getUniqueCallbackName("spawn");
    window[childCallbackName] = child;
  
    function cleanup(name) {
      delete window[name];
    }

    child.on("exit", code => {
        cleanup(childCallbackName);
    });

    if (!hasKernelInterface() || typeof ksu.spawn !== "function") {
      child.emit("error", new Error("当前环境不支持内核接口，无法执行命令"));
      return child;
    }

    try {
      ksu.spawn(
        command,
        JSON.stringify(args),
        JSON.stringify(options),
        childCallbackName
      );
    } catch (error) {
      child.emit("error", error);
      cleanup(childCallbackName);
    }
    return child;
  }

export function fullScreen(isFullScreen) {
  // 缺少接口时静默跳过，保证页面其余功能仍然可用
  if (hasKernelInterface() && typeof ksu.fullScreen === "function") {
    try {
      ksu.fullScreen(isFullScreen);
    } catch (error) {
      /* 忽略：全屏失败不影响功能 */
    }
  }
}

export function toast(message) {
  if (hasKernelInterface() && typeof ksu.toast === "function") {
    try {
      ksu.toast(message);
    } catch (error) {
      /* 忽略 */
    }
  }
}