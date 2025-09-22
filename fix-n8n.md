# Conectar a PostgreSQL y crear usuario directamente
docker exec -it n8n-n8nwithpostgres-irim7x-postgres-1 psql -U luargil -d n8n

# Dentro de PostgreSQL, ver usuarios existentes:
SELECT * FROM "user";

# Crear nuevo usuario (sustituir con hash de contraseña real)
INSERT INTO "user" (email, "firstName", "lastName", password, "globalRoleId", "personalizationAnswers", settings) 
VALUES (
  'luargil@gmail.com', 
  'Raul', 
  'Gil', 
  '$2a$10$hash_de_password_aqui', 
  (SELECT id FROM role WHERE name = 'owner'),
  '{}',
  '{}'
);

-- Actualizar el usuario existente con email y contraseña
UPDATE "user" 
SET 
  email = 'luargil@gmail.com',
  "firstName" = 'Raul',
  "lastName" = 'Gil',
  password = '$2a$12$ZhFQAzpW2pF0HrJPPKeBc.w7DCsYheOhW0vkQHqvbd/z2Mprkmp1y'
WHERE id = '60da3872-1c19-485c-b4d6-f639b0198fa2';

-- Verificar el cambio
SELECT id, email, "firstName", "lastName", "roleSlug" FROM "user";


-- Actualizar con tu hash personalizado (reemplaza NUEVO_HASH_AQUI)
UPDATE "user" 
SET password = '$2a$12$ZhFQAzpW2pF0HrJPPKeBc.w7DCsYheOhW0vkQHqvbd/z2Mprkmp1y'
WHERE email = 'luargil@gmail.com';

-- Verificar
SELECT email, password FROM "user";
\q