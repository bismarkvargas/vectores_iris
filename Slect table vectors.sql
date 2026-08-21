
SELECT TOP 1 
    ID, 
    Nombre, 
    EnviarAGPT(Contenido, 'Responde sobre:') AS RespuestaGPT
FROM VECTORESPKG.Documentos
ORDER BY 
    VECTOR_DOT_PRODUCT(
        Embedding, 
        TO_VECTOR(ObtenerEmbedding('¿Qué dice sobre IRIS?'), double)
    ) DESC
