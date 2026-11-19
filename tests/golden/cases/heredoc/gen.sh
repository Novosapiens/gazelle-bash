# Writes other scripts; their source lines are not dependencies of this one.
cat > out.sh <<EOF
source not_a_dep_plain.sh
EOF
cat <<-'EOF'
	. not_a_dep_dash_quoted.sh
	EOF
msg="$(cat <<"END"
source not_a_dep_in_subst.sh
END
)"
read -r x <<< "source not_a_dep_herestring.sh"
echo $(( 1 << 2 ))
source lib.sh
