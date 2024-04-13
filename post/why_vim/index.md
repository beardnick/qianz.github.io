
# 杀手级功能：vim模式

## 用代码的方式描述编辑操作

只要一个领域的工作可以用代码来描述那么就会带了生产力的巨大飞跃。

- html,css把图形用代码描述，就产生了前端生态
- docker把环境部署，安装，配置行为用代码描述就开创了云时代

同样的vim将编辑行为用代码描述出来就大大提高了编辑的效率。
vim模式让以下编辑器功能如虎添翼

### 快捷键

这是我最喜欢的一张vim指令速查表

![vim vim_cheatsheet](https://raw.githubusercontent.com/beardnick/static/master/imagesvim_cheatsheet.png)

vim的快捷键相比于其它编辑器，ide有以下优点

1. 快捷键丰富：内置几百个快捷键，另外支持自定义快捷键，可以组合出成千上万个快捷键
2. 快捷键覆盖所有操作：快捷键覆盖了所有操作，所以手不用去拿鼠标，大大提高效率
3. 快捷键方便、不伤手：大部分快捷键可以让手指不离开主键盘区，不需要按控制键，按起来效率高，保护小拇指

在第一第二点上大家可能觉得vscode，jetbrain也有很多快捷键，也支持快捷键自定义。确实如此，但是vscode，jetbrain上有很大一部分快捷键完全为其ui服务，例如打开终端，打开文件浏览器等等。
对于提升纯编辑体验的快捷键不多，只有比较通用的跳到行头，跳到行尾，复制，粘贴，删除，移动行等等。这些只够普通的编辑操作，稍微复杂点的操作就必须配合鼠标了，而动用鼠标则必然让手离
开主键盘区，这大大降低了编辑效率。同时因为编辑相关的快捷键少，也会让一些比较复杂的编辑场景如多光标编辑，宏操作受限。

### 多光标操作

vscode，jetbrain同样提供多光标操作的功能，但是多光标下无法方便地使用鼠标，只能用快捷键，而vscode,jetbrain本身的快捷键功能覆盖的编辑操作少，所以就无法进行复杂的多光标编辑

从vscode的文档的演示种可以看出来基本只能在多个光标前后进行一些编辑，光标移动依靠方向键移动

![vscode multi cursor](https://code.visualstudio.com/assets/docs/editor/codebasics/multicursor.gif)

vim在vim模式的加持下则可以做出非常复杂的多光标编辑操作，下面是vim多光标插件的演示效果

![visual multi](https://camo.githubusercontent.com/100be83770daaa30cdd285bcd321f00badd14a40c3415066e4de5cc347e0025e/68747470733a2f2f692e696d6775722e636f6d2f677746665578712e676966)

还想看更多非常强大的用法的演示，可以访问多光标插件的库[visual multi repository](https://github.com/mg979/vim-visual-multi)

### 宏

jetbrain,vscode没有内置宏功能，有第三方插件实现了宏录制的功能，可以把一些操作录制下来并绑定快捷键回放。同样，因为jetbrain,vscode的编辑快捷键少，所以导致宏录制本身功能十分受限，无法实现一些复杂的编辑操作。
对于vim，因为宏其实就是记录键盘敲击序列，所以实现起来十分容易。

#### 例子: 临时调试

些时候我们临时调试一些程序，就想知道程序有没有走到某些分支，我们可能随手就敲下

```javascript
normal code ...
console.log('reached 123');
normal code ...
```

- TODO: 这里要有一个演示视频 23-12-11 -

# 开放的生态

# 现代化的vim

