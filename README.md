# readingList

A list of articles I've read. View it here: https://read.jamesst.one. Automatically updated by a button I press on another service somewhere else.

A datasette instance also exists at https://api-read.jamesst.one/. This allows for quick analysis eg:

- here is a chart of [reads over time](https://api-read.jamesst.one/readingList/read#g.mark=line&g.x_column=date&g.x_type=temporal&g.y_column=rowid&g.y_type=quantitative) 
- here is a chart of [reads by domain](https://api-read.jamesst.one/readingList?sql=with%0D%0A++stage1+as+%28select+url%2C+INSTR%28url%2C+%27%2F%2F%27%29+as+idx_ss+from+read+where+url+is+not+null%29%2C%0D%0A++stage2+as+%28select+*%2C+IIF%28idx_ss+%3E+0%2C+SUBSTR%28url%2C+idx_ss%2B2%29%2C+url%29+as+dom1+from+stage1%29%2C%0D%0A++stage3+as+%28select+*%2C+INSTR%28dom1%2C+%27%2F%27%29+as+idx_s+from+stage2%29%2C%0D%0A++stage4+as+%28select+*%2C+IIF%28idx_s+%3E+0%2C+SUBSTR%28dom1%2C+1%2C+idx_s-1%29%2C+dom1%29+as+domain+from+stage3%29%0D%0Aselect+domain%2C+count%28*%29+from+stage4%0D%0Agroup+by+1+%0D%0Aorder+by+2+desc%0D%0A%0D%0A--select+distinct+domain+from+domains#g.mark=bar&g.x_column=domain&g.x_type=nominal&g.y_column=count(*)&g.y_type=quantitative)
