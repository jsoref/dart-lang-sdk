// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "platform/globals.h"
#if defined(DART_HOST_OS_WINDOWS)
#include <Psapi.h>
#include <Windows.h>
#include <combaseapi.h>
#include <stdio.h>
#include <tchar.h>
#endif

#include "vm/bootstrap_natives.h"
#include "vm/dart_api_impl.h"
#include "vm/exceptions.h"
#include "vm/globals.h"
#include "vm/native_entry.h"
#include "vm/object_store.h"

#if defined(DART_HOST_OS_LINUX) || defined(DART_HOST_OS_MACOS) ||              \
    defined(DART_HOST_OS_ANDROID) || defined(DART_HOST_OS_FUCHSIA)
#include <dlfcn.h>
#endif

namespace dart {

#if defined(USING_SIMULATOR) || (defined(DART_PRECOMPILER) && !defined(TESTING))

DART_NORETURN static void SimulatorUnsupported() {
#if defined(USING_SIMULATOR)
  Exceptions::ThrowUnsupportedError(
      "Not supported on simulated architectures.");
#else
  Exceptions::ThrowUnsupportedError("Not supported in precompiler.");
#endif
}

DEFINE_NATIVE_ENTRY(Ffi_dl_open, 0, 1) {
  SimulatorUnsupported();
}
DEFINE_NATIVE_ENTRY(Ffi_dl_processLibrary, 0, 0) {
  SimulatorUnsupported();
}
DEFINE_NATIVE_ENTRY(Ffi_dl_executableLibrary, 0, 0) {
  SimulatorUnsupported();
}
DEFINE_NATIVE_ENTRY(Ffi_dl_lookup, 1, 2) {
  SimulatorUnsupported();
}
DEFINE_NATIVE_ENTRY(Ffi_dl_getHandle, 0, 1) {
  SimulatorUnsupported();
}
DEFINE_NATIVE_ENTRY(Ffi_dl_providesSymbol, 0, 2) {
  SimulatorUnsupported();
}

DEFINE_NATIVE_ENTRY(Ffi_GetFfiNativeResolver, 1, 0) {
  SimulatorUnsupported();
}

#else  // defined(USING_SIMULATOR) ||                                          \
       // (defined(DART_PRECOMPILER) && !defined(TESTING))

// If an error occurs populates |error| (if provided) with an error message
// (caller must free this message when it is no longer needed).
static void* LoadDynamicLibrary(const char* library_file,
                                char** error = nullptr) {
  char* utils_error = nullptr;
  void* handle = Utils::LoadDynamicLibrary(library_file, &utils_error);
  if (utils_error != nullptr) {
    if (error != nullptr) {
      *error = OS::SCreate(
          /*use malloc*/ nullptr, "Failed to load dynamic library '%s': %s",
          library_file != nullptr ? library_file : "<process>", utils_error);
    }
    free(utils_error);
  }
  return handle;
}

#if defined(DART_HOST_OS_WINDOWS)
// On windows, nullptr signals trying a lookup in all loaded modules.
const nullptr_t kWindowsDynamicLibraryProcessPtr = nullptr;

void* co_task_mem_allocated = nullptr;

// If an error occurs populates |error| with an error message
// (caller must free this message when it is no longer needed).
void* LookupSymbolInProcess(const char* symbol, char** error) {
  // Force loading ole32.dll.
  if (co_task_mem_allocated == nullptr) {
    co_task_mem_allocated = CoTaskMemAlloc(sizeof(intptr_t));
    CoTaskMemFree(co_task_mem_allocated);
  }

  HANDLE current_process =
      OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE,
                  GetCurrentProcessId());
  if (current_process == nullptr) {
    *error = OS::SCreate(nullptr, "Failed to open current process.");
    return nullptr;
  }

  HMODULE modules[1024];
  DWORD cb_needed;
  if (EnumProcessModules(current_process, modules, sizeof(modules),
                         &cb_needed) != 0) {
    for (intptr_t i = 0; i < (cb_needed / sizeof(HMODULE)); i++) {
      if (auto result =
              reinterpret_cast<void*>(GetProcAddress(modules[i], symbol))) {
        CloseHandle(current_process);
        return result;
      }
    }
  }
  CloseHandle(current_process);

  *error = OS::SCreate(
      nullptr,  // Use `malloc`.
      "None of the loaded modules contained the requested symbol '%s'.",
      symbol);
  return nullptr;
}
#endif

// If an error occurs populates |error| with an error message
// (caller must free this message when it is no longer needed).
static void* ResolveSymbol(void* handle, const char* symbol, char** error) {
#if defined(DART_HOST_OS_WINDOWS)
  if (handle == kWindowsDynamicLibraryProcessPtr) {
    return LookupSymbolInProcess(symbol, error);
  }
#endif
  return Utils::ResolveSymbolInDynamicLibrary(handle, symbol, error);
}

static bool SymbolExists(void* handle, const char* symbol) {
  char* error = nullptr;
#if !defined(DART_HOST_OS_WINDOWS)
  Utils::ResolveSymbolInDynamicLibrary(handle, symbol, &error);
#else
  if (handle == nullptr) {
    LookupSymbolInProcess(symbol, &error);
  } else {
    Utils::ResolveSymbolInDynamicLibrary(handle, symbol, &error);
  }
#endif
  if (error != nullptr) {
    free(error);
    return false;
  }
  return true;
}

DEFINE_NATIVE_ENTRY(Ffi_dl_open, 0, 1) {
  GET_NON_NULL_NATIVE_ARGUMENT(String, lib_path, arguments->NativeArgAt(0));

  char* error = nullptr;
  void* handle = LoadDynamicLibrary(lib_path.ToCString(), &error);
  if (error != nullptr) {
    const String& msg = String::Handle(String::New(error));
    free(error);
    Exceptions::ThrowArgumentError(msg);
  }
  return DynamicLibrary::New(handle);
}

DEFINE_NATIVE_ENTRY(Ffi_dl_processLibrary, 0, 0) {
#if defined(DART_HOST_OS_LINUX) || defined(DART_HOST_OS_MACOS) ||              \
    defined(DART_HOST_OS_ANDROID) || defined(DART_HOST_OS_FUCHSIA)
  return DynamicLibrary::New(RTLD_DEFAULT);
#else
  return DynamicLibrary::New(kWindowsDynamicLibraryProcessPtr);
#endif
}

DEFINE_NATIVE_ENTRY(Ffi_dl_executableLibrary, 0, 0) {
  return DynamicLibrary::New(LoadDynamicLibrary(nullptr));
}

DEFINE_NATIVE_ENTRY(Ffi_dl_lookup, 1, 2) {
  GET_NON_NULL_NATIVE_ARGUMENT(DynamicLibrary, dlib, arguments->NativeArgAt(0));
  GET_NON_NULL_NATIVE_ARGUMENT(String, argSymbolName,
                               arguments->NativeArgAt(1));

  void* handle = dlib.GetHandle();

  char* error = nullptr;
  const uword pointer = reinterpret_cast<uword>(
      ResolveSymbol(handle, argSymbolName.ToCString(), &error));
  if (error != nullptr) {
    const String& msg = String::Handle(String::NewFormatted(
        "Failed to lookup symbol '%s': %s", argSymbolName.ToCString(), error));
    free(error);
    Exceptions::ThrowArgumentError(msg);
  }
  return Pointer::New(pointer);
}

DEFINE_NATIVE_ENTRY(Ffi_dl_getHandle, 0, 1) {
  GET_NON_NULL_NATIVE_ARGUMENT(DynamicLibrary, dlib, arguments->NativeArgAt(0));

  intptr_t handle = reinterpret_cast<intptr_t>(dlib.GetHandle());
  return Integer::NewFromUint64(handle);
}

DEFINE_NATIVE_ENTRY(Ffi_dl_providesSymbol, 0, 2) {
  GET_NON_NULL_NATIVE_ARGUMENT(DynamicLibrary, dlib, arguments->NativeArgAt(0));
  GET_NON_NULL_NATIVE_ARGUMENT(String, argSymbolName,
                               arguments->NativeArgAt(1));

  void* handle = dlib.GetHandle();
  return Bool::Get(SymbolExists(handle, argSymbolName.ToCString())).ptr();
}

// nullptr if no native resolver is installed.
static Dart_FfiNativeResolver GetFfiNativeResolver(Thread* const thread,
                                                   const String& lib_url_str) {
  const Library& lib =
      Library::Handle(Library::LookupLibrary(thread, lib_url_str));
  if (lib.IsNull()) {
    // It is not an error to not have a native resolver installed.
    return nullptr;
  }
  return lib.ffi_native_resolver();
}

// If an error occurs populates |error| with an error message
// (caller must free this message when it is no longer needed).
static void* FfiResolveWithFfiNativeResolver(Thread* const thread,
                                             Dart_FfiNativeResolver resolver,
                                             const String& symbol,
                                             intptr_t args_n,
                                             char** error) {
  auto* result = resolver(symbol.ToCString(), args_n);
  if (result == nullptr) {
    *error = OS::SCreate(/*use malloc*/ nullptr,
                         "Couldn't resolve function: '%s'", symbol.ToCString());
  }
  return result;
}

// Frees |error|.
static void ThrowFfiResolveError(const String& symbol,
                                 const String& asset,
                                 char* error) {
  const String& error_message = String::Handle(String::NewFormatted(
      "Couldn't resolve native function '%s' in '%s' : %s.\n",
      symbol.ToCString(), asset.ToCString(), error));
  free(error);
  Exceptions::ThrowArgumentError(error_message);
}

// FFI native C function pointer resolver.
static intptr_t FfiResolve(Dart_Handle asset_handle,
                           Dart_Handle symbol_handle,
                           uintptr_t args_n) {
  auto* const thread = Thread::Current();
  DARTSCOPE(thread);
  auto* const zone = thread->zone();
  const String& asset = Api::UnwrapStringHandle(zone, asset_handle);
  const String& symbol = Api::UnwrapStringHandle(zone, symbol_handle);
  char* error = nullptr;

  // Resolver resolution.
  auto resolver = GetFfiNativeResolver(thread, asset);
  if (resolver != nullptr) {
    void* ffi_native_result = FfiResolveWithFfiNativeResolver(
        thread, resolver, symbol, args_n, &error);
    if (error != nullptr) {
      ThrowFfiResolveError(symbol, asset, error);
    }
    return reinterpret_cast<intptr_t>(ffi_native_result);
  }

  // Resolution in current process.
#if !defined(DART_HOST_OS_WINDOWS)
  void* const result = Utils::ResolveSymbolInDynamicLibrary(
      RTLD_DEFAULT, symbol.ToCString(), &error);
#else
  void* const result = LookupSymbolInProcess(symbol.ToCString(), &error);
#endif
  if (error != nullptr) {
    ThrowFfiResolveError(symbol, asset, error);
  }
  return reinterpret_cast<intptr_t>(result);
}

// Bootstrap to get the FFI Native resolver through a `native` call.
DEFINE_NATIVE_ENTRY(Ffi_GetFfiNativeResolver, 1, 0) {
  return Pointer::New(reinterpret_cast<intptr_t>(FfiResolve));
}

#endif  // defined(USING_SIMULATOR) ||                                         \
        // (defined(DART_PRECOMPILER) && !defined(TESTING))

}  // namespace dart
