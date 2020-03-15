---
title: SpringBoot单元测试
date: "2020-02-29"
categories: 
- Java
tags:
- springboot
- spring
---

# 测试环境配置



### 1. 在idea的project structure中配置test目录

![test](test.png)

<!--more-->


### 2. 加入如下注解

```java
@RunWith(SpringRunner.class)
@SpringBootTest(classes = DeepApplication.class, webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
```

   + **@RunWith:** 是指使用哪一个类来运行单元测试，这里一般是SpringRunner.class
   + **@SpringBootTest:** 是让测试的时候找到运行的主类（@SpringBootApplication，带有main的），这样可以准备好ApplicationContext，有些时候找不到就需要手动配置类名
   + **WebEnvironment.RANDOM_PORT:** 使测试开始于随机端口，这样就可以解决MockServerContainer does not support addEndpoint 报错

### 3. 可以静态导入assert，mockmvc方便写判断

```java
import static org.junit.Assert.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultHandlers.print;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
```

### 4. 数据库自动回滚，防止改变数据库结构

```java
    @Transactional
    @Rollback
    public void test(){
        ...
    }
```

### 5. Controller的测试

配置mockmvc

```java
@AutoConfigureMockMvc
public class TestClass {

    @Autowired
    MockMvc mvc;

}
```

#### MockMvc使用实例

获取json数据并检查数据

```java
@Test
public void getEmployeeByIdAPI() throws Exception 
{
  mvc.perform( MockMvcRequestBuilders
      .get("/employees/{id}", 1)                                           // get router
      .accept(MediaType.APPLICATION_JSON))                                 // set response type
      .andDo(print())                                                      // print result
      .andExpect(status().isOk())                                          // expect http 200
      .andExpect(MockMvcResultMatchers.jsonPath("$.employeeId").value(1)); // expect data in json
}
```

POST数据并创建

```java
@Test
public void createEmployeeAPI() throws Exception 
{
  mvc.perform( MockMvcRequestBuilders
      .post("/employees")                                                     // post router
      .content(asJsonString(new EmployeeVO("firstName4", "email4@mail.com"))) // post json data
      .contentType(MediaType.APPLICATION_JSON)                                // set ContentType
      .accept(MediaType.APPLICATION_JSON))                                    // set return type
      .andExpect(status().isCreated())
      .andExpect(MockMvcResultMatchers.jsonPath("$.employeeId").exists());    // expect data in json
}
```

上传文件

```java
File file = new File(filepath); // 读取磁盘文件
// 注意这里第一个参数是填写表单时文件的名字
MultipartFile mockFile = new MockMultipartFile(file.getName(),new FileInputStream(file));  // 创建mockmultipartfile
String result = mvc.perform(
        multipart("/document")
        .file(mockFile))
        .andExpect(status().is(200))
        .andReturn()
        .getResponse()
        .getContentAsString();
```

### SeeAlso
https://howtodoinjava.com/spring-boot2/testing/spring-boot-mockmvc-example/
