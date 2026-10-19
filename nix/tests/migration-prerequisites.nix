# Immutable, hash-checked CPython 3.13 Linux fixture wheels. Never an activation step.
{ pkgs }:
let
  wheels = builtins.fromJSON ''
[
  {
    "name": "appnope-0.1.4-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/81/29/5ecc3a15d5a33e31b26c11426c45c501e439cb865d0bff96315d86443b78/appnope-0.1.4-py2.py3-none-any.whl",
    "sha256": "502575ee11cd7a28c0205f379b525beefebab9d161b7c964670864014ed7213c"
  },
  {
    "name": "asttokens-3.0.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/d4/2b/04b8a15f3a1c77bc79ddf5c73875327f34b4fa75982df2b76e45e402d364/asttokens-3.0.2-py3-none-any.whl",
    "sha256": "9da13157f5b28becde0bd374fc677dcd3c290614264eff096f167c469cd9f933"
  },
  {
    "name": "attrs-26.1.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/64/b4/17d4b0b2a2dc85a6df63d1157e028ed19f90d4cd97c36717afef2bc2f395/attrs-26.1.0-py3-none-any.whl",
    "sha256": "c647aa4a12dfbad9333ca4e71fe62ddc36f4e63b2d260a37a8b83d2f043ac309"
  },
  {
    "name": "cffi-2.1.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/95/95/86342356ff5953b3fb06f7ef7c5bee212d45e770abc7218d451b9148313c/cffi-2.1.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl",
    "sha256": "a931079504ecc49efed7744c476a5c343a92fabf66dec2db95edb1b2fdc770e2"
  },
  {
    "name": "colorama-0.4.6-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/d1/d6/3965ed04c63042e047cb6a3e6ed1a63a35087b6a609aa3a15ed8ac56c221/colorama-0.4.6-py2.py3-none-any.whl",
    "sha256": "4f1d9991f5acc0ca119f9d443620b77f9d6b33703e51011c16baf57afb285fc6"
  },
  {
    "name": "comm-0.2.3-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/60/97/891a0971e1e4a8c5d2b20bbe0e524dc04548d2307fee33cdeba148fd4fc7/comm-0.2.3-py3-none-any.whl",
    "sha256": "c615d91d75f7f04f095b30d1c1711babd43bdc6419c1be9886a85f2f4e489417"
  },
  {
    "name": "debugpy-1.8.21-cp313-cp313-manylinux_2_34_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/48/57/412421516afc3055fa577516f00beec3d663f9b0ab330639547ae6c57720/debugpy-1.8.21-cp313-cp313-manylinux_2_34_x86_64.whl",
    "sha256": "ecbd158386c31ffe71d46f72d44d56e66331ab9b16cad649156d514368f23ab2"
  },
  {
    "name": "decorator-5.3.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/05/7f/798705f5296a58ca505d600456748d1be48078eac8a7050d8a98bc9edb89/decorator-5.3.1-py3-none-any.whl",
    "sha256": "f47fe6fdbd2edd623ecfe36875d37aba411624e2670dd395dddae1358689bb3c"
  },
  {
    "name": "exceptiongroup-1.3.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/8a/0e/97c33bf5009bdbac74fd2beace167cab3f978feb69cc36f1ef79360d6c4e/exceptiongroup-1.3.1-py3-none-any.whl",
    "sha256": "a7a39a3bd276781e98394987d3a5701d0c4edffb633bb7a5144577f82c773598"
  },
  {
    "name": "executing-2.2.1-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/c1/ea/53f2148663b321f21b5a606bd5f191517cf40b7072c0497d3c92c4a13b1e/executing-2.2.1-py2.py3-none-any.whl",
    "sha256": "760643d3452b4d777d295bb167ccc74c64a81df23fb5e08eff250c425a4b2017"
  },
  {
    "name": "fastjsonschema-2.22.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/49/82/2755c7c982086f00d4dab85bc120ec35045a9fc2191893a6ce79afe94443/fastjsonschema-2.22.2-py3-none-any.whl",
    "sha256": "0fb3915616adac85ccfdd737d26be1089845d2019819505b42d39888458f74d4"
  },
  {
    "name": "greenlet-3.5.5-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/89/5d/398a1c71fa7a277deeb376c999979de6786f08fc2d5747a0b9d6e11738dd/greenlet-3.5.5-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "2eabb980975cba5b93a95f6f69287d05fc05ac955bfd6a320a7c083eeb52c0b0"
  },
  {
    "name": "ipykernel-7.3.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/3d/02/77b271f5dc58bfbc0b577c877b2365d1ffea2afe66a80c13f2312820348c/ipykernel-7.3.0-py3-none-any.whl",
    "sha256": "897eb64da762549ef610698fca5e9675195ec6ac8ec7f19d81ce1ca20c876057"
  },
  {
    "name": "ipython-9.16.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/bc/8e/1239df488393d61076653bfb29f759d0f60cab8e030abdf7c17c31539b51/ipython-9.16.1-py3-none-any.whl",
    "sha256": "4acae635506f6d352d94c4899a19d5f85f8bc4d230932342dca556fdab1c69b4"
  },
  {
    "name": "ipython_pygments_lexers-1.1.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/d9/33/1f075bf72b0b747cb3288d011319aaf64083cf2efef8354174e3ed4540e2/ipython_pygments_lexers-1.1.1-py3-none-any.whl",
    "sha256": "a9462224a505ade19a605f71f8fa63c2048833ce50abc86768a0d81d876dc81c"
  },
  {
    "name": "jedi-0.20.0-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/9a/93/242e2eab5fe682ffcb8b0084bde703a41d51e17ee0f3a31ff0d9d813620a/jedi-0.20.0-py2.py3-none-any.whl",
    "sha256": "7bdd9c2634f56713299976f4cbd59cb3fa92165cc5e05ea811fb253480728b67"
  },
  {
    "name": "jsonschema-4.26.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/69/90/f63fb5873511e014207a475e2bb4e8b2e570d655b00ac19a9a0ca0a385ee/jsonschema-4.26.0-py3-none-any.whl",
    "sha256": "d489f15263b8d200f8387e64b4c3a75f06629559fb73deb8fdfb525f2dab50ce"
  },
  {
    "name": "jsonschema_specifications-2025.9.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/41/45/1a4ed80516f02155c51f51e8cedb3c1902296743db0bbc66608a0db2814f/jsonschema_specifications-2025.9.1-py3-none-any.whl",
    "sha256": "98802fee3a11ee76ecaca44429fda8a41bff98b00a0f2838151b113f210cc6fe"
  },
  {
    "name": "jupyter_client-8.9.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/3f/6f/56d39bf385c5c27988aebaf0c18a2a17e960575740100973511018bd904e/jupyter_client-8.9.1-py3-none-any.whl",
    "sha256": "0b7a295bc46e8751e9adae84781f726c851c1d911bd793edc4a3bde942e3da81"
  },
  {
    "name": "jupyter_core-5.9.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/e7/e7/80988e32bf6f73919a113473a604f5a8f09094de312b9d52b79c2df7612b/jupyter_core-5.9.1-py3-none-any.whl",
    "sha256": "ebf87fdc6073d142e114c72c9e29a9d7ca03fad818c5d300ce2adc1fb0743407"
  },
  {
    "name": "jupytext-1.19.5-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/7c/c6/76ee9dacedcd8c67d8fa53dd975613733bdd28242a4c41518ff1c8aeaa64/jupytext-1.19.5-py3-none-any.whl",
    "sha256": "af22351202171116b986fe1f4f9233a13ca4a85d5eec57a87900ed48521dbae4"
  },
  {
    "name": "markdown_it_py-4.2.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/b3/81/4da04ced5a082363ecfa159c010d200ecbd959ae410c10c0264a38cac0f5/markdown_it_py-4.2.0-py3-none-any.whl",
    "sha256": "9f7ebbcd14fe59494226453aed97c1070d83f8d24b6fc3a3bcf9a38092641c4a"
  },
  {
    "name": "matplotlib_inline-0.2.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/41/09/5b161152e2d90f7b87f781c2e1267494aef9c32498df793f73ad0a0a494a/matplotlib_inline-0.2.2-py3-none-any.whl",
    "sha256": "3c821cf1c209f59fb2d2d64abbf5b23b67bcb2210d663f9918dd851c6da1fcf6"
  },
  {
    "name": "mdit_py_plugins-0.6.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/a5/69/6da5581c6a7fede7dc261bf4e67d6adca4196f176b43288b55b3db395b6e/mdit_py_plugins-0.6.1-py3-none-any.whl",
    "sha256": "214c82fb2ac524472ab6a5bcab1de80f73b50443e187f401bfd77efbc7c6481d"
  },
  {
    "name": "mdurl-0.1.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/b3/38/89ba8ad64ae25be8de66a6d463314cf1eb366222074cfda9ee839c56a4b4/mdurl-0.1.2-py3-none-any.whl",
    "sha256": "84008a41e51615a49fc9966191ff91509e3c40b939176e643fd50a5c2196b8f8"
  },
  {
    "name": "msgpack-1.2.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/79/d3/36a46a8ed992b781acbc05928bd5bee3c810cb0c3563bf81a7b0c04a1a76/msgpack-1.2.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "787c9bebb5833e8f6fc8abca3c0597683d8d87f56a8842b6b89c75a5f3176e2d"
  },
  {
    "name": "nbformat-5.11.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/be/4a/0eece9dad5e73230ca972f7bc29456ce7d74772f123d401fcf67379008f7/nbformat-5.11.0-py3-none-any.whl",
    "sha256": "f70a17f591a9ccd1c601d5e61a4b20972703926df0ba42458ce14bf575766bb6"
  },
  {
    "name": "nest_asyncio2-1.7.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/c5/3c/3179b85b0e1c3659f0369940200cd6d0fa900e6cefcc7ea0bc6dd0e29ffb/nest_asyncio2-1.7.2-py3-none-any.whl",
    "sha256": "f5dfa702f3f81f6a03857e9a19e2ba578c0946a4ad417b4c50a24d7ba641fe01"
  },
  {
    "name": "packaging-26.3-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/63/34/ba1c580383c9eada3711951fef0795c80b829a078d72188184bcab9dd527/packaging-26.3-py3-none-any.whl",
    "sha256": "d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c"
  },
  {
    "name": "parso-0.8.7-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/99/5d/8268b644392ee874ee82a635cd0df1773de230bde356c38de28e298392cc/parso-0.8.7-py2.py3-none-any.whl",
    "sha256": "a8926eb2a1b915486941fdbd31e86a4baf88fe8c210f25f2f35ecec5b574ca1c"
  },
  {
    "name": "pexpect-4.9.0-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/9e/c3/059298687310d527a58bb01f3b1965787ee3b40dce76752eda8b44e9a2c5/pexpect-4.9.0-py2.py3-none-any.whl",
    "sha256": "7236d1e080e4936be2dc3e326cec0af72acf9212a7e1d060210e70a47e253523"
  },
  {
    "name": "platformdirs-4.11.3-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/19/a9/c34aebedd3a4c9afe5101b1b8713710b3fec18087c8a36c35d2f909861bd/platformdirs-4.11.3-py3-none-any.whl",
    "sha256": "5ed065d443751de711da036041a7a214122efc4a4de393b3f4137ba5576540e7"
  },
  {
    "name": "prompt_toolkit-3.0.53-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/54/6f/84908cad2d6aa5144abcf7b42709fe4fdb459bc640ec7ac5786e7693dabc/prompt_toolkit-3.0.53-py3-none-any.whl",
    "sha256": "01c0891d7f9237d5e339f7d3e42cdae80b7534abb1c7c0e3352efba6231492f2"
  },
  {
    "name": "psutil-7.2.2-cp36-abi3-manylinux2010_x86_64.manylinux_2_12_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/b5/70/5d8df3b09e25bce090399cf48e452d25c935ab72dad19406c77f4e828045/psutil-7.2.2-cp36-abi3-manylinux2010_x86_64.manylinux_2_12_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "076a2d2f923fd4821644f5ba89f059523da90dc9014e85f8e45a5774ca5bc6f9"
  },
  {
    "name": "ptyprocess-0.7.0-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/22/a6/858897256d0deac81a172289110f31629fc4cee19b6f01283303e18c8db3/ptyprocess-0.7.0-py2.py3-none-any.whl",
    "sha256": "4b41f3967fce3af57cc7e94b888626c18bf37a083e3651ca8feeb66d492fef35"
  },
  {
    "name": "pure_eval-0.2.3-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/8e/37/efad0257dc6e593a18957422533ff0f87ede7c9c6ea010a2177d738fb82f/pure_eval-0.2.3-py3-none-any.whl",
    "sha256": "1db8e35b67b3d218d818ae653e27f06c3aa420901fa7b081ca98cbedc874e0d0"
  },
  {
    "name": "pycparser-3.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/0c/c3/44f3fbbfa403ea2a7c779186dc20772604442dde72947e7d01069cbe98e3/pycparser-3.0-py3-none-any.whl",
    "sha256": "b727414169a36b7d524c1c3e31839a521725078d7b2ff038656844266160a992"
  },
  {
    "name": "pygments-2.20.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/f4/7e/a72dd26f3b0f4f2bf1dd8923c85f7ceb43172af56d63c7383eb62b332364/pygments-2.20.0-py3-none-any.whl",
    "sha256": "81a9e26dd42fd28a23a2d169d86d7ac03b46e2f8b59ed4698fb4785f946d0176"
  },
  {
    "name": "pynvim-0.6.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/54/2d/c28b9293975ed9ee05e52f1d316cb402ba6edb232baa0497754a70182ca2/pynvim-0.6.0-py3-none-any.whl",
    "sha256": "29f92ff3fde9e52c263e6bfd7f30345be05bfc7b5c21484da1cc38a8d8e5e98f"
  },
  {
    "name": "python_dateutil-2.9.0.post0-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/ec/57/56b9bcc3c9c6a792fcbaf139543cee77261f3651ca9da0c93f5c1221264b/python_dateutil-2.9.0.post0-py2.py3-none-any.whl",
    "sha256": "a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427"
  },
  {
    "name": "pyyaml-6.0.3-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/74/27/e5b8f34d02d9995b80abcef563ea1f8b56d20134d8f4e5e81733b1feceb2/pyyaml-6.0.3-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "0f29edc409a6392443abf94b9cf89ce99889a1dd5376d94316ae5145dfedd5d6"
  },
  {
    "name": "pyzmq-27.1.0-cp312-abi3-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/f8/9b/c108cdb55560eaf253f0cbdb61b29971e9fb34d9c3499b0e96e4e60ed8a5/pyzmq-27.1.0-cp312-abi3-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "43ad9a73e3da1fab5b0e7e13402f0b2fb934ae1c876c51d0afff0e7c052eca31"
  },
  {
    "name": "referencing-0.37.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/2c/58/ca301544e1fa93ed4f80d724bf5b194f6e4b945841c5bfd555878eea9fcb/referencing-0.37.0-py3-none-any.whl",
    "sha256": "381329a9f99628c9069361716891d34ad94af76e461dcb0335825aecc7692231"
  },
  {
    "name": "rpds_py-2026.6.3-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/57/d7/fe978efc2ae50abe48eb7464668ea99f53c010c60aeebb7b35ad27f23661/rpds_py-2026.6.3-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
    "sha256": "acac386b453c2516111b50985d60ce46e7fadb5ea71ae7b25f4c946935bf27cf"
  },
  {
    "name": "six-1.17.0-py2.py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/b7/ce/149a00dd41f10bc29e5921b496af8b574d8413afcd5e30dfa0ed46c2cc5e/six-1.17.0-py2.py3-none-any.whl",
    "sha256": "4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274"
  },
  {
    "name": "stack_data-0.6.3-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/f1/7b/ce1eafaf1a76852e2ec9b22edecf1daa58175c090266e9f6c64afcd81d91/stack_data-0.6.3-py3-none-any.whl",
    "sha256": "d5558e0c25a4cb0853cddad3d77da9891a08cb85dd9f9f91b9f8cd66e511e695"
  },
  {
    "name": "tomli-2.4.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/10/8f/d3ddb16c5a4befdf31a23307f72828686ab2096f068eaf56631e136c1fdd/tomli-2.4.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "f3c6818a1a86dd6dca7ddcaaf76947d5ba31aecc28cb1b67009a5877c9a64f3f"
  },
  {
    "name": "tornado-6.5.8-cp39-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/6e/de/f2e733f386b85962d1b1dc82cd63d169b5b4580062b35397eac9244a41fe/tornado-6.5.8-cp39-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl",
    "sha256": "547d63f450d570c14fe0e8db2cfb14c9bbd1c2503b4a6612586267955aa47b58"
  },
  {
    "name": "traitlets-5.16.1-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/ad/66/0d785f0bc5e4315a96c989bb476d0fc07ea4f85132550c7b156ca2035d52/traitlets-5.16.1-py3-none-any.whl",
    "sha256": "f775618166caa0396c8e337099240f2bd3e5e917d203b2e6fbe21a58d3cb1f6b"
  },
  {
    "name": "typing_extensions-4.16.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl",
    "sha256": "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8"
  },
  {
    "name": "wcwidth-0.8.2-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/96/42/3e5985a0a7e57de470b320c6d6a1a67c844f6737a587f3d44dd13d1819e7/wcwidth-0.8.2-py3-none-any.whl",
    "sha256": "d63947694a0539a1d51e01eda7caf800c291020e6cdd7e28ad7b14dd33ad4f85"
  },
  {
    "name": "duckdb-1.5.5-cp313-cp313-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/3e/c5/41bef391fb8b23dbc133c9f2ba016e7a7a8124513d2cc1b430f1897d87e4/duckdb-1.5.5-cp313-cp313-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
    "sha256": "078e6a60dd8eedde5832f45422ca5c4a6b8c837aeabd8a56ca0b7d933f588053"
  },
  {
    "name": "pyarrow-25.0.0-cp313-cp313-manylinux_2_28_x86_64.whl",
    "url": "https://files.pythonhosted.org/packages/b5/5d/f790fb6965ab54c9da0dda7856abc75fd0d7648d865f8d603c111d203a64/pyarrow-25.0.0-cp313-cp313-manylinux_2_28_x86_64.whl",
    "sha256": "6f9dbd83e91c239a1f5ee7ce13f108b5f6c0efbe40a4375260d8f08b43ad05e9"
  },
  {
    "name": "standard_mailcap-3.13.0-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/83/ed/a49825f8ff1bd4f1f77fb631441c00c8e831a4a3decacd34f1cf3e24bb44/standard_mailcap-3.13.0-py3-none-any.whl",
    "sha256": "4f509e11cb5a4700e91118630447643398b183ff3bb734011c8c030b3d671f0a"
  },
  {
    "name": "visidata-3.4-py3-none-any.whl",
    "url": "https://files.pythonhosted.org/packages/52/0a/23878c577da6227faa79c26ec80567e2998f8eb655d61295b18a2f163509/visidata-3.4-py3-none-any.whl",
    "sha256": "9b88473c7bfb5a1752bea5870cc6edd3474cf529ac16c0e465d3ec0014ea99fb"
  }
]
  '';
  fetched = map (wheel: pkgs.fetchurl { inherit (wheel) name url sha256; }) wheels;
  wheelhouse = pkgs.runCommand "dotfiles-migration-offline-wheels" { } (''
    mkdir -p "$out"
  '' + pkgs.lib.concatMapStringsSep "\n" (wheel: ''
    ln -s ${wheel} "$out/${wheel.name}"
  '') fetched);
  notebookRequirements = pkgs.runCommand "dotfiles-frozen-notebook-requirements" {
    nativeBuildInputs = [ pkgs.uv ];
  } ''
    export HOME="$TMPDIR/home" UV_CACHE_DIR="$TMPDIR/cache" UV_PYTHON_DOWNLOADS=never UV_NO_MANAGED_PYTHON=1
    mkdir -p "$HOME" project
    cp ${../../.config/nvim/python/pyproject.toml} project/pyproject.toml
    cp ${../../.config/nvim/python/uv.lock} project/uv.lock
    uv --no-config export --frozen --offline --no-dev --no-emit-project --project project --output-file "$out" > /dev/null
  '';
  # Nix glibc deliberately ignores /etc/ld.so.cache, and the external PyArrow
  # wheel's RUNPATH prevents inherited interpreter RPATH lookup. Link the native
  # C++ runtime explicitly in this fixture interpreter; external wheel bytes,
  # the pinned Python version/stdlib, and sanitized production probes stay real.
  python = pkgs.runCommand "dotfiles-fixture-python-${pkgs.python313.version}" {
    nativeBuildInputs = [ pkgs.patchelf ];
  } ''
    mkdir -p "$out/bin"
    cp ${pkgs.python313}/bin/python3.13 "$out/bin/python3.13"
    chmod u+w "$out/bin/python3.13"
    patchelf --add-needed ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 "$out/bin/python3.13"
    ln -s python3.13 "$out/bin/python3"
    ln -s python3.13 "$out/bin/python"
  '';
in {
  inherit wheelhouse notebookRequirements python;
  manager = "${pkgs.writeShellScriptBin "systemctl" ''
    ${pkgs.systemd}/bin/systemctl "$@"
    status=$?
    if [ "$status" -eq 0 ] && [ "''${2-}" = stop ] && [ -e "$HOME/.local/state/fixture/fail-after-stop" ]; then
      printf '%s\n' 'fixture: delegated stop succeeded; injected exit 73' >&2
      exit 73
    fi
    exit "$status"
  ''}/bin/systemctl";
  prepare = pkgs.writeShellApplication {
    name = "prepare-dotfiles-native-fixture";
    runtimeInputs = [ pkgs.uv pkgs.coreutils ];
    text = ''
      export UV_PYTHON_DOWNLOADS=never UV_NO_MANAGED_PYTHON=1 UV_OFFLINE=1
      export UV_CACHE_DIR="$HOME/.cache/uv"
      export UV_TOOL_DIR="$HOME/.local/share/uv/tools"
      export UV_TOOL_BIN_DIR="$HOME/.local/bin"
      export UV_PYTHON_INSTALL_DIR="$HOME/.local/share/uv/python"
      export UV_PYTHON_BIN_DIR="$HOME/.local/bin"
      uv --no-config tool install --python ${python}/bin/python3.13 \
        --offline --no-index --find-links ${wheelhouse} \
        --with pyarrow==25.0.0 --with duckdb==1.5.5 visidata==3.4
      export UV_PROJECT_ENVIRONMENT="$HOME/.local/share/nvim/notebook-python"
      # Frozen sync prefers original registry URLs over find-links for missing
      # wheels. Seed the real UV environment from a hash-checked frozen export,
      # then run the exact frozen sync offline to audit the complete environment.
      uv --no-config venv --python ${python}/bin/python3.13 "$UV_PROJECT_ENVIRONMENT"
      uv --no-config pip install --python "$UV_PROJECT_ENVIRONMENT/bin/python" \
        --offline --no-index --find-links ${wheelhouse} --require-hashes -r ${notebookRequirements}
      uv --no-config sync --python ${python}/bin/python3.13 --offline \
        --frozen --no-dev --no-install-project --find-links ${wheelhouse} \
        --project "$HOME/.config/nvim/python"
    '';
  };
}
