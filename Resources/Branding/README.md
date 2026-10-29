# Poieva 图标

白色圆角底、深蓝色 P 字标与蓝色对话标记。轮廓使用共享矢量源 [`../Design/poieva-mark.svg`](../Design/poieva-mark.svg)，菜单栏取同一轮廓并交给系统绘制单色外观。

`scripts/make-icon.swift` 添加白底、边缘和阴影，生成 16–1024 像素的 PNG 与 ICNS。修改图形时先编辑 SVG，再通过构建脚本生成应用；此处的 256 / 1024 像素 PNG 为可直接使用的预览与导出图。
