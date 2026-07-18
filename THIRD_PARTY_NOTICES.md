# Third-Party Notices and Trademarks / 第三方声明与商标

This document identifies third-party names and properties referenced by ChatGPT Skin Studio. It is not a license grant, proof of authorization, or substitute for legal review.

本文列出 ChatGPT Skin Studio 涉及的第三方名称与作品。本文不授予许可、不证明已经获得授权，也不能替代法律审查。

## OpenAI products and marks

ChatGPT Skin Studio is an independent, unofficial project. It is not affiliated with, endorsed by, sponsored by, or supported by OpenAI.

“OpenAI,” “ChatGPT,” “Codex,” and associated product names, logos, and marks are the property of OpenAI or their respective owners. References are used only to identify the compatible third-party application and user interface.

ChatGPT Skin Studio 是独立非官方项目，与 OpenAI 没有隶属、认可、赞助或支持关系。“OpenAI”“ChatGPT”“Codex”及相关产品名称、Logo 和标志归 OpenAI 或各自权利人所有；文中提及仅用于说明兼容的第三方 App 和界面。

## Bundled theme references

The v0.1.0 bundle is prepared with theme names and artwork that include the following references:

| Theme ID | Reference | Notice |
|---|---|---|
| `dota-juggernaut` | Dota / Juggernaut | Unofficial fan theme; Dota and related characters/marks belong to their respective owners |
| `dream-westward-journey` | 梦幻西游 / 剑侠客 | Unofficial fan theme; the title, character, and related marks belong to their respective owners |
| `kartrider-dao` | KartRider / 跑跑卡丁车 / Dao | Unofficial fan theme; the title, character, and related marks belong to their respective owners |
| `minecraft-creeper` | Minecraft / Creeper | Unofficial fan theme; Minecraft and related characters/marks belong to Microsoft, Mojang, or their respective owners |
| `naruto-itachi` | Naruto / Itachi | Unofficial fan theme; Naruto and related characters/marks belong to their respective owners |

The remaining bundled themes use generic project theme names, but that alone is not a representation that every visual element is free of third-party rights.

这些主题是非官方 fan theme，不代表项目拥有相关作品、角色、名称或标志，也不代表获得权利人的授权、赞助或认可。其余内置主题使用通用名称，但这也不构成对画面不存在第三方权利的保证。

### Distribution warning

Including a disclaimer does not create permission to distribute protected artwork. Anyone packaging, mirroring, redistributing, or commercially using this project must independently confirm that they have the necessary rights or remove the affected assets. The repository's lack of a license file also means public source visibility does not grant redistribution rights.

免责声明不会产生传播受保护图片的许可。打包、镜像、再分发或商业使用本项目的任何主体，都应独立确认已经获得必要权利，否则应移除相关资源。本仓库当前没有许可证文件，公开可见源码本身也不授予再分发权。

If you are a rights holder and believe an asset should be removed, report it through the repository's GitHub Issues with enough information to identify the work and the affected file. Do not include private personal documents in a public Issue.

权利人如认为某项资源应被移除，可通过仓库 GitHub Issues 提供足以识别作品和受影响文件的信息；不要在公开 Issue 中提交私人证件或敏感材料。

## User-imported content

ChatGPT Skin Studio can import a local image as a personal theme. The importer validates and re-encodes the file, but it does not determine copyright, trademark, publicity, privacy, or contractual rights. Users are responsible for the content they choose and how they use it.

ChatGPT Skin Studio 可将本地图片导入为个人主题。导入器只负责校验和重新编码，不判断 copyright、trademark、肖像、隐私或合同权利。用户需对所选内容及其使用方式负责。

## Software dependencies

Third-party software included in a binary distribution remains governed by its own license. ChatGPT Skin Studio pins [Sparkle 2.9.2](https://github.com/sparkle-project/Sparkle) through Swift Package Manager. Sparkle integration does not mean automatic updates are active until a release publishes a signed archive and appcast.

二进制分发包中的第三方软件仍适用其自身许可证。ChatGPT Skin Studio 通过 Swift Package Manager 固定使用 [Sparkle 2.9.2](https://github.com/sparkle-project/Sparkle)。集成 Sparkle 不代表自动更新已经上线；对应 Release 仍需发布签名更新包和 appcast。

### Sparkle license

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
