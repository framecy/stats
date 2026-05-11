Stats 风扇控制安装指南 (Apple Silicon)
=====================================

由于 macOS 对自行编译（Ad-hoc 签名）应用的权限限制，风扇控制助手可能无法自动安装。
如果 Stats 应用中提示无法控制风扇，请按照以下步骤手动操作：

1. 将 Stats.app 拖入“应用程序”文件夹 (/Applications)。
2. 右键点击本文件夹中的 `install_helper.sh`，选择“拷贝”。
3. 打开“终端” (Terminal)，输入以下命令：
   sudo 
4. 将脚本粘贴到 sudo 后面（或者直接将脚本拖入终端窗口）。
5. 最终命令看起来应该像这样：
   sudo /Volumes/Stats/install_helper.sh
6. 按回车并输入您的开机密码。
7. 安装完成后，重启 Stats 应用。

注意：本脚本需要管理员权限 (sudo) 才能将助手程序安装到系统目录。
