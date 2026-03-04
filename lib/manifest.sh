#!/usr/bin/env bash

# ============================================================================
# Stealth Deployment Manifest & Scheduler
# ============================================================================

# 定义所有步骤的执行函数名及其依赖（空格分隔）
declare -A STEP_DEPS=(
    ["deploy_step_01"]=""
    ["deploy_step_02"]="deploy_step_01"
    ["deploy_step_03"]="deploy_step_01"
    ["deploy_step_04"]="deploy_step_02"
    ["deploy_step_05"]="deploy_step_02"
    ["deploy_step_06"]="deploy_step_03 deploy_step_04"
    ["deploy_step_07"]="deploy_step_05 deploy_step_06"
    ["deploy_step_08"]="deploy_step_07"
)

# 保存最终调度得到的执行序列
_EXECUTION_PLAN=()

# 拓扑排序解析步骤依赖
_build_execution_plan() {
    local -A visited=()
    local -A in_path=()

    _visit() {
        local step="$1"
        
        # 环检测
        if [[ "${in_path[$step]}" == "1" ]]; then
            log_error "检测到执行步骤循环依赖，异常步骤: $step"
            exit 1
        fi
        
        # 已访问过则跳过
        if [[ "${visited[$step]}" == "1" ]]; then
            return
        fi

        in_path[$step]=1
        
        # 递归处理依赖
        if [[ -n "${STEP_DEPS[$step]}" ]]; then
            for dep in ${STEP_DEPS[$step]}; do
                _visit "$dep"
            done
        fi
        
        in_path[$step]=0
        visited[$step]=1
        _EXECUTION_PLAN+=("$step")
    }

    # 遍历所有定义的步骤，自动消除重复
    for step in "${!STEP_DEPS[@]}"; do
        _visit "$step"
    done
}

execute_all_steps() {
    _EXECUTION_PLAN=()   # 清空上一次结果，幂等性
    _build_execution_plan
    
    log_info "已计算出步骤依赖序列，计划执行 ${#_EXECUTION_PLAN[@]} 个步骤:"
    log_info "-> ${_EXECUTION_PLAN[*]}"
    
    # 按照计算出的序列串行执行。
    # 得益于主循环开启了 set -e，任何函数的非零返回都会直接熔断部署过程。
    for step in "${_EXECUTION_PLAN[@]}"; do
        if type "$step" &>/dev/null; then
            "$step"
        else
            log_error "未找到步骤实现: $step"
            exit 1
        fi
    done
}
