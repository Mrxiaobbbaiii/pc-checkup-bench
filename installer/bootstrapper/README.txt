WebView2 bootstrapper 放置目录（构建依赖，exe 不入库）

文件名必须是：MicrosoftEdgeWebview2Setup.exe
下载地址（官方直链）：
https://go.microsoft.com/fwlink/p/?LinkId=2124703

浏览器打开上面链接会直接下载 MicrosoftEdgeWebview2Setup.exe（约 2MB），
下载完把它放进本目录即可。build.ps1 -Setup 的守卫 3 会检查它在不在。

用途：异机没装 Edge WebView2 运行库时，安装器会静默调它补装（1023 片1）。
