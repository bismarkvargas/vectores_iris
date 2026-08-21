Class User.Utils Extends %RegisteredObject
{

/// Devuelve la API key de OpenAI.
/// Se lee de la global ^Config("OpenAIKey") del namespace y, si esta vacia,
/// de la variable de entorno OPENAI_API_KEY del contenedor.
/// Nunca escribir la key dentro de esta clase: el codigo se publica.
ClassMethod ApiKey() As %String
{
    Set key = $Get(^Config("OpenAIKey"))
    If key = "" Set key = $System.Util.GetEnviron("OPENAI_API_KEY")
    Quit key
}

/// Guarda la API key en esta instancia de IRIS.
/// Uso: Do ##class(User.Utils).SetApiKey("sk-...")
ClassMethod SetApiKey(pKey As %String) As %Status
{
    Set ^Config("OpenAIKey") = pKey
    Quit $$$OK
}

ClassMethod Setup() As %Status
{
    Set sc = $$$OK
    Set tNamespace = $NAMESPACE
    
    New $NAMESPACE
    Set $NAMESPACE = "%SYS"
    If '##class(Security.SSLConfigs).Exists("DefaultSSL") {
        Write "Creando configuración SSL 'DefaultSSL'...",!
        Set sc = ##class(Security.SSLConfigs).Create("DefaultSSL")
        If $$$ISERR(sc) Write "Error creando SSL Config: ", $SYSTEM.Status.GetErrorText(sc),! Return sc
    } Else {
        Write "Configuración SSL 'DefaultSSL' ya existe.",!
    }
    
    Set $NAMESPACE = tNamespace
    
    Set sql = "CREATE TABLE VECTORESPKG.Documentos ("_
              "ID INTEGER PRIMARY KEY IDENTITY, "_
              "Nombre VARCHAR(255), "_
              "Contenido VARCHAR(MAX), "_
              "Embedding VECTOR(DOUBLE, 1536))"
              
    Set tStatement = ##class(%SQL.Statement).%New()
    Set sc = tStatement.%Prepare(sql)
    
    If $$$ISERR(sc) {
        Write "Error preparando SQL: ", $SYSTEM.Status.GetErrorText(sc), !
        Return sc
    }
    
    Set tResult = tStatement.%Execute()
    
    If (tResult.%SQLCODE = 0) {
        Write "Tabla VECTORESPKG.Documentos creada exitosamente.",!
    } ElseIf (tResult.%SQLCODE = -201) {
        Write "La tabla VECTORESPKG.Documentos ya existe.",!
    } Else {
        Write "Error creando tabla: SQLCODE=", tResult.%SQLCODE, " ", tResult.%Message,!
        Set sc = $$$ERROR($$$GeneralError, "Error SQL creando tabla: "_tResult.%Message)
    }
    
    Return sc
}

ClassMethod EnviarAGPT(pContexto As %String, pInstruccion As %String) As %String [ SqlName = EnviarAGPT, SqlProc ]
{
    Set request = ##class(%Net.HttpRequest).%New()
    Set request.Server = "api.openai.com"
    Set request.Https = 1
    Set request.SSLConfiguration = "DefaultSSL" 
    
    If $ISOBJECT(pContexto) {
        If pContexto.%Extends("%Stream.Object") {
            Do pContexto.Rewind()
            Set pContexto = pContexto.Read(32000)
        }
    } ElseIf $LISTVALID(pContexto) {
        Set tStream = ##class(%Stream.GlobalCharacter).%Open(pContexto)
        If $ISOBJECT(tStream) {
            Do tStream.Rewind()
            Set pContexto = tStream.Read(32000)
        }
    }
    
    Set apiKey = ..ApiKey()
    If apiKey = "" {
        Return "Error: no hay API key configurada. Ejecute Do ##class(User.Utils).SetApiKey(""sk-..."")"
    }
    Do request.SetHeader("Authorization", "Bearer "_apiKey)
    Do request.SetHeader("Content-Type", "application/json; charset=utf-8")
    
    Set body = {
        "model": "gpt-4o-mini",
        "messages": [
            {"role": "system", "content": (pInstruccion)},
            {"role": "user", "content": (pContexto)}
        ]
    }
    
    Set jsonBody = body.%ToJSON()
    Do request.EntityBody.Write($ZCONVERT(jsonBody, "O", "UTF8"))

    Set sc = request.Post("/v1/chat/completions")
    If $$$ISERR(sc) {
        Write "Error HTTP Post: ", $SYSTEM.Status.GetErrorText(sc), !
        Return "Error de red: "_$SYSTEM.Status.GetErrorText(sc)
    }
    If '$ISOBJECT(request.HttpResponse) {
        Write "Error: No se recibió respuesta HTTP del servidor.", !
        Return "Error: No se recibió respuesta HTTP del servidor."
    }
    If request.HttpResponse.StatusCode '= 200 {
        Write "Error API Code: ", request.HttpResponse.StatusCode, !
        Write "Respuesta: ", request.HttpResponse.Data.Read(), !
        Return "Error API Code: "_request.HttpResponse.StatusCode_" - "_request.HttpResponse.Data.Read()
    }
    
    Set response = {}.%FromJSON(request.HttpResponse.Data.Read())
    If response.error'="" Return "API Error: "_response.error.message

    Quit response.choices.%Get(0).message.content
}

ClassMethod ObtenerEmbedding(pTexto As %String) As %String [ SqlName = ObtenerEmbedding, SqlProc ]
{
    Set request = ##class(%Net.HttpRequest).%New()
    Set request.Server = "api.openai.com"
    Set request.Https = 1
    Set request.SSLConfiguration = "DefaultSSL"
    
    If $ISOBJECT(pTexto) {
        If pTexto.%Extends("%Stream.Object") {
            Do pTexto.Rewind()
            Set pTexto = pTexto.Read(32000)
        }
    } ElseIf $LISTVALID(pTexto) {
        Set tStream = ##class(%Stream.GlobalCharacter).%Open(pTexto)
        If $ISOBJECT(tStream) {
            Do tStream.Rewind()
            Set pTexto = tStream.Read(32000)
        }
    }
    
    Set apiKey = ..ApiKey()
    If apiKey = "" {
        Write "Error: no hay API key configurada. Ejecute Do ##class(User.Utils).SetApiKey(""sk-..."")", !
        Quit "[]"
    }
    Do request.SetHeader("Authorization", "Bearer "_apiKey)
    Do request.SetHeader("Content-Type", "application/json; charset=utf-8")

    Set body = { "model": "text-embedding-3-small", "input": (pTexto) }
    
    Set jsonBody = body.%ToJSON()
    Do request.EntityBody.Write($ZCONVERT(jsonBody, "O", "UTF8"))
    
    Set sc = request.Post("/v1/embeddings")
    
    If $$$ISERR(sc) {
        Write "Error HTTP Post (System Error): ", $SYSTEM.Status.GetErrorText(sc), !
        Quit "[]"
    }
    
    If '$ISOBJECT(request.HttpResponse) {
        Write "Error: No se recibió respuesta HTTP del servidor (HttpResponse es null).", !
        Quit "[]"
    }

    If request.HttpResponse.StatusCode '= 200 {
        Write "Error API Code: ", request.HttpResponse.StatusCode, !
        
        Set responseData = ""
        If $ISOBJECT(request.HttpResponse.Data) {
            Do request.HttpResponse.Data.Rewind()
            Set responseData = request.HttpResponse.Data.Read()
        }
        Write "Respuesta: ", responseData, !
        Quit "[]"
    }

    Try {
        Set response = {}.%FromJSON(request.HttpResponse.Data)
        Return response.data.%Get(0).embedding.%ToJSON()
    } Catch ex {
        Write "Error parsing JSON response: ", ex.Name, " - ", ex.Data, !
        Return "[]"
    }
}

}
