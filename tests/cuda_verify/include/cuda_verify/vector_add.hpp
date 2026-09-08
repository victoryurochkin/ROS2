#pragma once
#include <cstddef>
#include <string>

namespace cuda_verify
{

/// Собирает текстовый отчёт об устройствах CUDA, видимых процессу.
/// Работает и без GPU: тогда возвращает описание ошибки.
std::string describe_devices();

/// Запускает сложение векторов на GPU и проверяет результат на CPU.
/// @param n размер вектора
/// @param error сюда пишется текст ошибки, если функция вернула false
/// @return true, если ядро выполнилось и результат корректен
bool run_vector_add(std::size_t n, std::string & error);

/// Версии, с которыми собран бинарник (compile-time) и которые доступны
/// в рантайме — расхождение обычно означает несовместимость драйвера.
std::string describe_versions();

}  // namespace cuda_verify
