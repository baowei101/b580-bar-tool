|  |                   |                                       |       |Max    |        |Max  |Global |                     |
|  |                   |                                       |       |compute|Max work|sub  |mem    |                     |
|ID|        Device Type|                                   Name|Version|units  |group   |group|size   |       Driver version|
|--|-------------------|---------------------------------------|-------|-------|--------|-----|-------|---------------------|
| 0| [level_zero:gpu:0]|                Intel Arc B580 Graphics|   20.1|    160|    1024|   32| 12809M|        1.17.39758+10|
|ID|        Device Type|Reorder|
|--|-------------------|-------|
| 0| [level_zero:gpu:0]|      Y|
| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen35 9B Q6_K                 |   6.94 GiB |     8.95 B | SYCL       |  99 |          pp4096 |       2222.17 ± 1.83 |
| qwen35 9B Q6_K                 |   6.94 GiB |     8.95 B | SYCL       |  99 |           tg128 |         53.18 ± 0.06 |
